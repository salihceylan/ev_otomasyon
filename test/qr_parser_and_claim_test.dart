import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/common/qr_flow.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Cihaz eşleştirme (claim) diyaloğu: normalizasyon, giriş kısıtları, hata kodu eşleme, çift dokunuş,
/// kilit geri sayımı, müşteri adına eşleme (OTP) ve taranan karekodların türüne göre yönlendirilmesi.
/// (Karekod ayrıştırıcı tabloları `test/services/qr_parsers_test.dart` içindedir.)
void main() {
  const uid = 'AHBU-S3-1A2B3C';
  const pin = '482916';

  Future<Opened<bool>> open(WidgetTester tester, E2Env env, {String? initialUid, String? initialPin}) {
    return openFromHost<bool>(
      tester,
      env.state,
      (context) => ClaimManualDialog.show(context, initialUid: initialUid, initialPin: initialPin),
    );
  }

  Future<void> fill(WidgetTester tester, {String uidText = uid, String pinText = pin}) async {
    await typeInto(tester, 'field_claim_uid', uidText);
    await typeInto(tester, 'field_claim_pin', pinText);
  }

  group('giriş alanları', () {
    testWidgets('başlangıç değerleri (QR) forma yazılır; UID büyük harfe çevrilir', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env, initialUid: uid, initialPin: pin);

      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_uid'))).controller!.text, uid);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_pin'))).controller!.text, pin);

      await typeInto(tester, 'field_claim_uid', 'ahbu-s3-aabbcc');
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_uid'))).controller!.text, 'AHBU-S3-AABBCC');
    });

    testWidgets('UID yalnızca [A-Z0-9-]; PIN yalnızca rakam ve en çok 6 hane', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);

      await typeInto(tester, 'field_claim_uid', 'ahbu s3_1a/2b!3c');
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_uid'))).controller!.text, 'AHBUS31A2B3C');
      await typeInto(tester, 'field_claim_pin', '12ab34-56789');
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_pin'))).controller!.text, '123456');
    });

    testWidgets('boş/geçersiz UID ve eksik PIN reddedilir; sunucuya istek gitmez', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);

      await tapKey(tester, 'btn_claim_submit');
      expect(find.text('Lütfen cihaz seri numarasını (UID) girin'), findsOneWidget);
      expect(find.text('Lütfen 6 haneli kurulum PIN kodunu girin'), findsOneWidget);

      await fill(tester, uidText: 'ABC123', pinText: '123');
      await tapKey(tester, 'btn_claim_submit');
      expect(find.text('Geçerli bir cihaz kimliği girin (AHBU- ile başlar)'), findsOneWidget);
      expect(find.text('PIN kodu tam 6 haneli olmalıdır'), findsOneWidget);

      // Davet/devir önekleri cihaz kimliği OLAMAZ.
      await fill(tester, uidText: 'AHBU-TR-ABCDEF', pinText: pin);
      await tapKey(tester, 'btn_claim_submit');
      expect(find.text('Geçerli bir cihaz kimliği girin (AHBU- ile başlar)'), findsOneWidget);
      expect(env.cloud.claimArgs, isEmpty);
    });

    testWidgets('PIN varsayılan olarak gizlidir ve göster düğmesiyle görünür olur', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env, initialPin: pin);
      EditableText field() => tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('field_claim_pin')), matching: find.byType(EditableText)));
      expect(field().obscureText, isTrue);

      await tester.tap(find.byTooltip('PIN\'i göster'));
      await tester.pump();
      expect(field().obscureText, isFalse);
    });
  });

  group('eşleştirme', () {
    testWidgets('başarılı: UID normalleştirilmiş, PIN 6 hane, ev adı kırpılmış gönderilir; diyalog `true` ile kapanır', (tester) async {
      final env = e2Env(role: null);
      final opened = await open(tester, env);

      await fill(tester, uidText: 'ahbu-s3-1a2b3c');
      await typeInto(tester, 'field_claim_home_name', '  Yazlık Daire  ');
      await tapKey(tester, 'btn_claim_submit');

      final args = env.cloud.claimArgs.single;
      expect(args['uid'], uid);
      expect(args['pinLength'], 6);
      expect(args['homeName'], 'Yazlık Daire');
      expect(args['targetOwner'], isNull);
      expect(opened.result, isTrue);
      expect(find.byType(ClaimManualDialog), findsNothing);
    });

    testWidgets('boş ev adı "Evim" olur', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);
      await fill(tester);
      await typeInto(tester, 'field_claim_home_name', '   ');
      await tapKey(tester, 'btn_claim_submit');
      expect(env.cloud.claimArgs.single['homeName'], 'Evim');
    });

    testWidgets('çift dokunuşta yalnızca BİR istek gider; istek sürerken geri tuşu ve dışarı dokunma kapatmaz', (tester) async {
      final env = e2Env(role: null);
      final gate = Completer<void>();
      env.cloud.claimGate = gate;
      final opened = await open(tester, env);
      await fill(tester);

      await tester.tap(find.byKey(const Key('btn_claim_submit')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('btn_claim_submit')), warnIfMissed: false);
      await tester.pump();
      expect(env.cloud.claimArgs, hasLength(1));

      await tester.tapAt(const Offset(4, 4)); // dışarı dokunma
      await tester.binding.handlePopRoute(); // sistem geri tuşu
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ClaimManualDialog), findsOneWidget, reason: 'istek sürerken kapanmaz');

      gate.complete();
      await settle(tester);
      expect(opened.result, isTrue);
    });

    testWidgets('diyalog dışarı dokunmayla KAPANMAZ (barrierDismissible: false)', (tester) async {
      final env = e2Env(role: null);
      await open(tester, env);

      await tester.tapAt(const Offset(4, 4));
      await settle(tester);

      expect(find.byType(ClaimManualDialog), findsOneWidget);
    });

    testWidgets('eşleştirme yetkisi olmayan hesap (misafir/servis oturumu) için form yerine açık mesaj gösterilir', (tester) async {
      final env = e2Env(
        role: 'guest',
        home: HomeModel(
          id: kHomeA,
          name: 'Ev A',
          role: 'guest',
          guestValidFrom: kTestNow.subtract(const Duration(hours: 1)),
          guestValidUntil: kTestNow.add(const Duration(hours: 2)),
        ),
      );
      await open(tester, env);

      expect(find.byKey(const Key('claim_forbidden')), findsOneWidget);
      expect(find.byKey(const Key('field_claim_uid')), findsNothing);
    });

    testWidgets('kısmi başarı uyarıları kullanıcıya GÖSTERİLİR (başarı ekranında)', (tester) async {
      final env = e2Env(role: null);
      env.cloud.claimResultToReturn = const ClaimResult(
        homeId: kHomeA,
        homeName: 'Daire 5',
        deviceUuid: uid,
        warnings: <String>['Müşteriye davet e-postası gönderilemedi.'],
      );
      final opened = await open(tester, env);
      await fill(tester);

      await tapKey(tester, 'btn_claim_submit');

      expect(find.byKey(const Key('claim_success')), findsOneWidget);
      expect(find.text('Müşteriye davet e-postası gönderilemedi.'), findsOneWidget);
      // Pano buluta kendiliğinden bağlanır (CONTRACTS §3f): başarı ekranında bilgi satırı.
      expect(find.byKey(const Key('claim_cloud_note')), findsOneWidget);
      expect(find.textContaining('kendiliğinden buluta bağlanır'), findsOneWidget);
      expect(opened.done, isFalse, reason: 'uyarıyı okumadan kapanmaz');
      await tapKey(tester, 'btn_claim_done');
      expect(opened.result, isTrue);
    });
  });

  group('hata kodu eşleme (ham istisna metni gösterilmez)', () {
    Future<E2Env> submitWithError(WidgetTester tester, Object error) async {
      final env = e2Env(role: null);
      env.cloud.claimError = error;
      await open(tester, env);
      await fill(tester);
      await tapKey(tester, 'btn_claim_submit');
      return env;
    }

    testWidgets('423 PIN_LOCKED: kalan süre gösterilir, düğme geri sayım yapar ve süre dolunca açılır', (tester) async {
      final env = await submitWithError(
        tester,
        apiError(423, 'PIN kilitli.', code: 'PIN_LOCKED', retryAfter: const Duration(minutes: 5)),
      );

      expect(textOf(tester, 'claim_error'), contains('geçici olarak kilitlendi'));
      expect(textOf(tester, 'claim_error'), contains('5 dakika'));
      expect(find.byKey(const Key('claim_lock_notice')), findsOneWidget);
      expect(find.text('Bekleyin (5:00)'), findsOneWidget);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_claim_submit'))).onPressed, isNull);

      env.cloud.claimError = null;
      env.clock.advance(const Duration(minutes: 5, seconds: 1));
      await tester.pump();
      expect(find.byKey(const Key('claim_lock_notice')), findsNothing);
      expect(tester.widget<ElevatedButton>(find.byKey(const Key('btn_claim_submit'))).onPressed, isNotNull);
    });

    testWidgets('429: hız sınırı mesajı ve bekleme', (tester) async {
      await submitWithError(tester, apiError(429, 'x', code: 'RATE_LIMITED', retryAfter: const Duration(seconds: 30)));
      expect(textOf(tester, 'claim_error'), 'Çok fazla istek gönderildi. 30 saniye bekleyip tekrar deneyin.');
      expect(find.text('Bekleyin (0:30)'), findsOneWidget);
    });

    testWidgets('409: cihaz zaten bağlı', (tester) async {
      await submitWithError(tester, apiError(409, 'Cihaz zaten sahiplenilmiş.', code: 'CONFLICT'));
      expect(textOf(tester, 'claim_error'), contains('zaten bir daireye bağlı'));
    });

    testWidgets('403: yetki yok', (tester) async {
      await submitWithError(tester, apiError(403, 'Bu işlem için yetkiniz yok.', code: 'FORBIDDEN'));
      expect(textOf(tester, 'claim_error'), contains('yetkiniz yok'));
    });

    testWidgets('403 yanlış kurulum PIN kodu (sunucu FORBIDDEN + remaining_attempts): sunucu mesajı, "yetkiniz yok" DEĞİL',
        (tester) async {
      await submitWithError(
        tester,
        apiError(403, 'Geçersiz kurulum PIN kodu. Kalan deneme hakkı: 4', code: 'FORBIDDEN', remaining: 4),
      );
      expect(textOf(tester, 'claim_error'), 'Geçersiz kurulum PIN kodu. Kalan deneme hakkı: 4');
      expect(textOf(tester, 'claim_error'), isNot(contains('yetkiniz yok')));
    });

    test('yanlış PIN eşlemesi: kalan deneme yoksa da mesaj PIN diyorsa sunucu mesajı; sayı mesajda yoksa eklenir', () {
      expect(
        claimErrorMessage(apiError(403, 'Geçersiz kurulum PIN kodu.', code: 'FORBIDDEN')),
        'Geçersiz kurulum PIN kodu.',
      );
      expect(
        claimErrorMessage(apiError(403, 'PIN yanlış.', code: 'FORBIDDEN', remaining: 2)),
        'PIN yanlış. Kalan deneme: 2.',
      );
      expect(claimErrorMessage(apiError(403, 'Bu işlem için yetkiniz yok.', code: 'FORBIDDEN')), contains('yetkiniz yok'));
    });

    testWidgets('ağ hatası: bağlantı mesajı', (tester) async {
      await submitWithError(tester, apiError(0, 'ham ağ hatası', code: 'NETWORK'));
      expect(textOf(tester, 'claim_error'), 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.');
    });

    testWidgets('hatalı PIN (401) kalan deneme hakkıyla gösterilir', (tester) async {
      await submitWithError(tester, apiError(401, 'Kurulum PIN\'i hatalı.', code: 'INVALID_CREDENTIALS', remaining: 3));
      expect(textOf(tester, 'claim_error'), 'Kurulum PIN\'i hatalı. Kalan deneme: 3.');
    });

    testWidgets('bilinmeyen istisna: genel mesaj, ham metin yok', (tester) async {
      await submitWithError(tester, StateError('ERROR: duplicate key value violates unique constraint'));
      expect(find.textContaining('duplicate'), findsNothing);
      expect(textOf(tester, 'claim_error'), 'Eşleştirme tamamlanamadı. Lütfen tekrar deneyin.');
    });

    test('claimErrorMessage saf işlev olarak da aynı eşlemeyi yapar', () {
      expect(claimErrorMessage(apiError(423, 'x', code: 'PIN_LOCKED', retryAfter: const Duration(seconds: 90))), contains('90 saniye'));
      expect(claimErrorMessage(apiError(423, 'x', code: 'PIN_LOCKED')), contains('Bir süre'));
      expect(claimErrorMessage(apiError(500, 'Sunucu şu anda yanıt veremiyor.')), 'Sunucu şu anda yanıt veremiyor.');
    });
  });

  group('müşteri adına eşleme (servis personeli / OTP)', () {
    Future<E2Env> openAsStaff(WidgetTester tester) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      await open(tester, env);
      return env;
    }

    testWidgets('anahtar yalnızca servis personeli/süper kullanıcıya görünür; ev sahibine görünmez', (tester) async {
      final owner = e2Env();
      await open(tester, owner);
      expect(find.byKey(const Key('switch_claim_for_customer')), findsNothing);
      await tapKey(tester, 'btn_claim_cancel');

      final staff = e2Env(role: null, globalRole: 'service_user');
      await open(tester, staff);
      expect(find.byKey(const Key('switch_claim_for_customer')), findsOneWidget);
    });

    testWidgets('kendi kimliğini müşteri olarak giremez', (tester) async {
      final env = await openAsStaff(tester);
      await fill(tester);
      await tapKey(tester, 'switch_claim_for_customer');

      await typeInto(tester, 'field_claim_customer', kUserEmail.toUpperCase());
      await tapKey(tester, 'btn_claim_send_otp');

      expect(textOf(tester, 'claim_error'), 'Kendi hesabınıza eşleme yapamazsınız; müşterinin bilgilerini girin');
      expect(env.cloud.claimOtpArgs, isEmpty);

      await typeInto(tester, 'field_claim_customer', '0555 111 22 33'); // kendi telefonu
      await tapKey(tester, 'btn_claim_send_otp');
      expect(find.textContaining('Kendi hesabınıza eşleme yapamazsınız'), findsOneWidget);
      expect(env.cloud.claimOtpArgs, isEmpty);
    });

    testWidgets('OTP gönderilince cihaz kimliği, PIN ve müşteri alanları KİLİTLENİR; "Bilgileri Düzenle" kilidi açar', (tester) async {
      final env = await openAsStaff(tester);
      await fill(tester);
      await tapKey(tester, 'switch_claim_for_customer');
      await typeInto(tester, 'field_claim_customer', 'Musteri@Ornek.test');

      await tapKey(tester, 'btn_claim_send_otp');

      expect(env.cloud.claimOtpArgs.single, <String, String>{'uid': uid, 'target': 'musteri@ornek.test'});
      expect(find.byKey(const Key('claim_otp_sent')), findsOneWidget);
      for (final key in <String>['field_claim_uid', 'field_claim_pin', 'field_claim_customer']) {
        expect(isReadOnly(tester, key), isTrue, reason: '$key kilitli');
      }
      expect(tester.widget<SwitchListTile>(find.byKey(const Key('switch_claim_for_customer'))).onChanged, isNull);

      await tapKey(tester, 'btn_claim_unlock');
      for (final key in <String>['field_claim_uid', 'field_claim_pin', 'field_claim_customer']) {
        expect(isReadOnly(tester, key), isFalse, reason: '$key açıldı');
      }
      expect(find.byKey(const Key('field_claim_otp')), findsNothing);
    });

    testWidgets('OTP yeniden gönderimi sunucunun bekleme süresine uyar', (tester) async {
      final env = await openAsStaff(tester);
      await fill(tester);
      await tapKey(tester, 'switch_claim_for_customer');
      await typeInto(tester, 'field_claim_customer', 'musteri@ornek.test');
      await tapKey(tester, 'btn_claim_send_otp');

      expect(find.text('Yeniden gönder (0:30)'), findsOneWidget);
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_claim_resend_otp'))).onPressed, isNull);

      env.clock.advance(const Duration(seconds: 31));
      await tester.pump();
      expect(tester.widget<TextButton>(find.byKey(const Key('btn_claim_resend_otp'))).onPressed, isNotNull);
    });

    testWidgets('OTP girilmeden/eksikken eşleme gönderilmez; doğru kodla müşteri + OTP birlikte gider', (tester) async {
      final env = await openAsStaff(tester);
      await fill(tester);
      await tapKey(tester, 'switch_claim_for_customer');
      await typeInto(tester, 'field_claim_customer', 'musteri@ornek.test');

      // OTP gönderilmeden eşleme olmaz.
      await tapKey(tester, 'btn_claim_submit');
      expect(textOf(tester, 'claim_error'), 'Önce müşteriye doğrulama kodu gönderin.');
      expect(env.cloud.claimArgs, isEmpty);

      await tapKey(tester, 'btn_claim_send_otp');
      await typeInto(tester, 'field_claim_otp', '12');
      await tapKey(tester, 'btn_claim_submit');
      expect(textOf(tester, 'claim_error'), 'Müşterinin söylediği 6 haneli kodu girin.');
      expect(env.cloud.claimArgs, isEmpty);

      await typeInto(tester, 'field_claim_otp', '135790');
      await tapKey(tester, 'btn_claim_submit');
      final args = env.cloud.claimArgs.single;
      expect(args['targetOwner'], 'musteri@ornek.test');
      expect(args['otpLength'], 6);
    });

    testWidgets('müşteri hesabı açıldığı ve davet gittiği bilgisi başarı ekranında gösterilir', (tester) async {
      final env = await openAsStaff(tester);
      env.cloud.claimResultToReturn = ClaimResult(
        homeId: kHomeA,
        homeName: 'Daire 5',
        deviceUuid: uid,
        customerAccount: const CustomerAccountInfo(created: true, inviteSent: true, status: 'pending_invite'),
        technicianAccessExpiresAt: DateTime.utc(2026, 10, 4, 12),
      );
      await fill(tester);
      await tapKey(tester, 'switch_claim_for_customer');
      await typeInto(tester, 'field_claim_customer', 'musteri@ornek.test');
      await tapKey(tester, 'btn_claim_send_otp');
      await typeInto(tester, 'field_claim_otp', '135790');

      await tapKey(tester, 'btn_claim_submit');

      expect(find.text('Müşteri için yeni hesap açıldı ve davet e-postası gönderildi.'), findsOneWidget);
      expect(find.textContaining('Kurulum erişiminiz'), findsOneWidget);
    });
  });

  group('taranan karekodun yönlendirilmesi (routeScannedCode)', () {
    Future<E2Env> pumpHost(WidgetTester tester, {String role = 'owner'}) async {
      final env = e2Env(role: role);
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in <String, String>{
                    'qr_claim': 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$uid&pin=$pin',
                    'qr_invite': 'AHBU-INVITE:AHBU-AB12CD34EF',
                    'qr_transfer': 'AHBU-TRANSFER:ABCDEF123456',
                    'qr_wifi': 'WIFI:T:WPA;S:EvAgi;P:parola1234;;',
                    'qr_unknown': 'merhaba dünya',
                    'qr_loose_uid': 'AHBU-S3-1A2B3C',
                  }.entries)
                    ElevatedButton(
                      key: Key(entry.key),
                      onPressed: () => routeScannedCode(context, entry.value),
                      child: Text(entry.key),
                    ),
                ],
              ),
            ),
          ),
        ),
        size: const Size(800, 1800),
      );
      return env;
    }

    testWidgets('cihaz etiketi -> eşleştirme diyaloğu UID ve PIN ile dolu açılır', (tester) async {
      await pumpHost(tester);
      await tapKey(tester, 'qr_claim');

      expect(find.byType(ClaimManualDialog), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_uid'))).controller!.text, uid);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_claim_pin'))).controller!.text, pin);
    });

    testWidgets('davet ve devir kodları -> katılma diyaloğu (türüne göre) kodla dolu açılır', (tester) async {
      await pumpHost(tester);
      await tapKey(tester, 'qr_invite');
      expect(find.byType(JoinHomeDialog), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_join_code'))).controller!.text, 'AHBU-AB12CD34EF');
      await tapKey(tester, 'btn_join_cancel');

      await tapKey(tester, 'qr_transfer');
      expect(find.byType(JoinHomeDialog), findsOneWidget);
      expect(tester.widget<TextFormField>(find.byKey(const Key('field_join_code'))).controller!.text, 'ABCDEF123456');
    });

    testWidgets('Wi-Fi karekodu burada kullanılamaz: açık Türkçe uyarı, diyalog açılmaz', (tester) async {
      await pumpHost(tester);
      await tapKey(tester, 'qr_wifi');

      expect(find.textContaining('Bu bir Wi-Fi karekodu'), findsOneWidget);
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.byType(JoinHomeDialog), findsNothing);
    });

    testWidgets('tanınmayan metin ve ÇIPLAK UID cihaz kimliği SAYILMAZ (ham metin UUID olmaz)', (tester) async {
      await pumpHost(tester);

      await tapKey(tester, 'qr_unknown');
      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.textContaining('Geçersiz karekod formatı'), findsOneWidget);

      await tapKey(tester, 'qr_loose_uid');
      expect(find.byType(ClaimManualDialog), findsNothing, reason: 'PIN\'siz çıplak UID eşleştirme başlatmaz');
    });

    testWidgets('eşleştirme yetkisi olmayan hesapta etiket karekodu eşleştirme açmaz', (tester) async {
      final env = e2Env(role: 'owner');
      env.cloud.restoreServiceSession(
        accessToken: 'servis',
        info: ServiceSessionInfo(homeId: kHomeA, homeName: 'Servis', expiresAt: kTestNow.add(const Duration(hours: 2))),
      );
      env.state
        ..setCurrentUserForTesting(const UserModel(id: '', email: '', fullName: 'Servis', role: 'service_session'))
        ..setHomesForTesting(<HomeModel>[testHome(role: 'service_session')], activeHome: testHome(role: 'service_session'));
      late BuildContext captured;
      await pumpApp(
        tester,
        state: env.state,
        child: Builder(builder: (context) {
          captured = context;
          return const Scaffold(body: SizedBox());
        }),
      );

      unawaited(routeScannedCode(captured, 'https://evotomasyon.gudeteknoloji.com.tr/claim?uid=$uid&pin=$pin'));
      await settle(tester);

      expect(find.byType(ClaimManualDialog), findsNothing);
      expect(find.text('Bu hesapla cihaz eşleştiremezsiniz.'), findsOneWidget);
    });
  });
}
