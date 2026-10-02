import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/auth/change_password_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/delete_account_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/forgot_password_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/magic_link_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/phone_otp_dialog.dart';
import 'package:ev_otomasyon/ui/pages/auth/register_page.dart';
import 'package:ev_otomasyon/ui/pages/auth/service_pin_dialog.dart';
import 'package:ev_otomasyon/ui/pages/claim/claim_manual_dialog.dart';
import 'package:ev_otomasyon/ui/pages/claim/qr_scanner_page.dart';
import 'package:ev_otomasyon/ui/pages/family/family_members_page.dart';
import 'package:ev_otomasyon/ui/pages/family/invite_family_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/join_home_dialog.dart';
import 'package:ev_otomasyon/ui/pages/family/transfer_ownership_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/biometric_prompt_dialog.dart';
import 'package:ev_otomasyon/ui/widgets/user_profile_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e2_support.dart';

/// E2 ekranları **dar ekranda ve büyük yazı ölçeğinde** (erişilebilirlik): hiçbir ekran/diyalog taşma
/// (RenderFlex/overflow) ya da başka çizim istisnası üretmez; eylem düğmelerine ulaşılabilir.
///
/// Her senaryo ekranı açar ve birkaç tipik duruma (doğrulama hataları, ikinci adım, sonuç/uyarı
/// görünümleri, yazarak onay) geçirir; her adımdan sonra özel durum yokluğu denetlenir.
void main() {
  // En zorlu gerçekçi yapılandırmalar: 360 dp genişlikte iki kat yazı; en küçük ekranda (320x568) 1,5 ve 2 kat.
  const configs = <(Size, double)>[
    (Size(360, 640), 2.0),
    (Size(320, 568), 1.5),
    (Size(320, 568), 2.0),
  ];

  const uid = 'AHBU-S3-1A2B3C';
  const longName = 'Çok Uzun İsimli Bir Aile Üyesi Ve Çok Uzun Bir Soyadı Daha';
  const longEmail = 'cok.uzun.eposta.adresi.ornek.kullanici@cok-uzun-bir-alan-adi.ornek.test';

  /// Çerçevenin bildirdiği hata ayrıntıları (ilgili widget'ın dosya:satır konumu dahil) test başına toplanır.
  final collected = <String>[];

  /// Özel durum varsa (ör. RenderFlex taşması) ilgili widget'ın konumuyla birlikte başarısız olur.
  void noException(WidgetTester tester, String step) {
    final exception = tester.takeException();
    if (exception == null) return;
    final where = <String>[
      for (final text in collected)
        for (final line in text.split('\n'))
          if (line.contains('overflowed by') || line.contains('Row:file') || line.contains('Column:file') || line.contains('file:///'))
            line.trim(),
    ];
    collected.clear();
    fail('$step: ${exception is FlutterError ? exception.message : exception}\n${where.take(14).join('\n')}');
  }

  /// Düğmeyi görünür kılar, **kare çizdirir** (kaydırma sonrası konum güncellensin) ve dokunur.
  Future<void> tapVisible(WidgetTester tester, String key) async {
    final finder = find.byKey(Key(key));
    expect(finder, findsOneWidget, reason: 'düğme bulunamadı: $key');
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.tap(finder);
    await settle(tester);
  }

  Future<void> confirmTyped(WidgetTester tester, String phrase) async {
    expect(find.byKey(const Key('field_confirm_phrase')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field_confirm_phrase')), phrase);
    await tester.pump();
    await tester.tap(find.byKey(const Key('btn_confirm_destructive')));
    await settle(tester);
  }

  Future<Opened<T>> open<T>(WidgetTester tester, E2Env env, Size size, Future<T?> Function(BuildContext) show) =>
      openFromHost<T>(tester, env.state, size: size, show);

  final scenarios = <String, Future<void> Function(WidgetTester tester, Size size)>{
    'giriş sayfası': (tester, size) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, size: size, child: const LoginPage());
      await settle(tester);
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_login'); // boş alanlar: doğrulama hataları
      noException(tester, 'doğrulama hataları');
      await tapVisible(tester, 'btn_toggle_password');
      noException(tester, 'şifre göster');
    },
    'kayıt sayfası': (tester, size) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, size: size, child: const RegisterPage());
      await settle(tester);
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_register_submit');
      noException(tester, 'doğrulama hataları');
    },
    'şifremi unuttum': (tester, size) async {
      final env = e2Env(authenticated: false);
      await open<void>(tester, env, size, (c) => ForgotPasswordDialog.show(c));
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_send_code'); // boş: kimlik hatası
      noException(tester, 'kimlik hatası');
      await typeInto(tester, 'field_identifier', 'ayse@ornek.test');
      await tapVisible(tester, 'btn_send_code');
      noException(tester, 'ikinci adım (kod + yeni şifre)');
      await tapVisible(tester, 'btn_reset_password'); // boş: alan hataları
      noException(tester, 'sıfırlama hataları');
    },
    'telefonla giriş (SMS)': (tester, size) async {
      final env = e2Env(authenticated: false);
      await open<void>(tester, env, size, (c) => PhoneOtpDialog.show(c));
      noException(tester, 'açılış');
      await tapText(tester, 'Kod Gönder'); // boş telefon
      noException(tester, 'telefon hatası');
      await typeInto(tester, 'field_phone', '05551112233');
      await tapText(tester, 'Kod Gönder');
      noException(tester, 'kod adımı');
      await tapText(tester, 'Giriş Yap'); // boş kod
      noException(tester, 'kod hatası');
    },
    'e-postadaki bağlantı': (tester, size) async {
      final env = e2Env(authenticated: false);
      await open<void>(tester, env, size, (c) => MagicLinkDialog.show(c));
      noException(tester, 'açılış');
      await typeInto(tester, 'field_magic_link', 'bu-bir-baglanti-degil');
      await tapVisible(tester, 'btn_magic_link_continue');
      noException(tester, 'geçersiz bağlantı hatası');
    },
    'şifre değiştirme sayfası': (tester, size) async {
      final env = e2Env();
      await pumpApp(tester, state: env.state, size: size, child: const ChangePasswordPage());
      await settle(tester);
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_change_password');
      noException(tester, 'doğrulama hataları');
    },
    'zorunlu şifre değiştirme sayfası': (tester, size) async {
      final env = e2Env();
      await pumpApp(tester, state: env.state, size: size, child: const ChangePasswordPage(forced: true));
      await settle(tester);
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_change_password');
      noException(tester, 'doğrulama hataları');
    },
    'hesabı sil': (tester, size) async {
      final env = e2Env();
      await open<void>(tester, env, size, (c) => DeleteAccountDialog.show(c));
      noException(tester, 'açılış');
      await typeInto(tester, 'field_delete_password', 'ornek-parola-1234');
      noException(tester, 'parola girildi');
    },
    'profil': (tester, size) async {
      final env = e2Env();
      env.state.setCurrentUserForTesting(const UserModel(id: kUserId, email: longEmail, fullName: longName));
      await open<void>(tester, env, size, (c) => UserProfileDialog.show(c));
      noException(tester, 'açılış (uzun ad ve e-posta)');
    },
    'biyometrik istem': (tester, size) async {
      final env = e2Env();
      await open<bool>(tester, env, size, (c) => BiometricPromptDialog.show(c, label: 'Yüz Tanıma / Parmak İzi'));
      noException(tester, 'açılış');
    },
    'aile ve misafir listesi': (tester, size) async {
      final env = e2Env();
      env.cloud.members = <HomeMember>[
        const HomeMember(userId: 'uye-sahip', fullName: 'Ev Sahibi Ali', role: 'owner', email: 'ali@ornek.test'),
        const HomeMember(userId: 'uye-1', fullName: longName, role: 'resident', email: longEmail),
        HomeMember(userId: 'uye-2', fullName: longName, role: 'guest', validUntil: kTestNow.add(const Duration(hours: 30))),
      ];
      env.state.setCurrentUserForTesting(const UserModel(id: 'uye-sahip', email: 'ali@ornek.test', fullName: 'Ev Sahibi Ali'));
      await pumpApp(tester, state: env.state, size: size, child: const FamilyMembersPage());
      await settle(tester);
      noException(tester, 'liste');
      await tapVisible(tester, 'btn_remove_member_uye-1');
      noException(tester, 'silme onayı');
    },
    'davet': (tester, size) async {
      final env = e2Env();
      await open<void>(tester, env, size, (c) => InviteFamilyDialog.show(c));
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_generate_member_invite');
      noException(tester, 'aile kodu');
      await tapText(tester, 'Süreli Misafir');
      await tapVisible(tester, 'btn_generate_guest_invite');
      noException(tester, 'misafir kodu');
    },
    'eve katıl (davet önizlemesi)': (tester, size) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = JoinCodePreview(
        isTransfer: false,
        homeName: 'Çok Uzun Bir Daire Adı Ve Çok Uzun Bir Sokak Adı Daire 14',
        residentCount: 12,
        role: 'guest',
        guestValidFrom: kTestNow,
        guestValidUntil: kTestNow.add(const Duration(hours: 40)),
      );
      await open<bool>(tester, env, size, (c) => JoinHomeDialog.show(c));
      noException(tester, 'açılış');
      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapVisible(tester, 'btn_join_continue');
      noException(tester, 'önizleme');
    },
    'eve katıl (devir önizlemesi)': (tester, size) async {
      final env = e2Env(role: null);
      env.cloud.previewToReturn = const JoinCodePreview(
        isTransfer: true,
        homeName: 'Çok Uzun Bir Daire Adı Ve Çok Uzun Bir Sokak Adı Daire 14',
        residentCount: 3,
        role: 'owner',
      );
      await open<bool>(tester, env, size, (c) => JoinHomeDialog.show(c));
      await typeInto(tester, 'field_join_code', 'AHBU-TR-ABCDEF123456');
      await tapVisible(tester, 'btn_join_continue');
      noException(tester, 'devir önizlemesi + yıkıcı uyarı');
    },
    'daire devri (ev sahibi)': (tester, size) async {
      final env = e2Env();
      await open<void>(tester, env, size, (c) => TransferOwnershipDialog.show(c));
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_initiate_transfer'); // hedef zorunlu hatası
      noException(tester, 'hedef hatası');
      await typeInto(tester, 'field_transfer_target', longEmail);
      await tapVisible(tester, 'btn_initiate_transfer');
      noException(tester, 'yazarak onay penceresi (uzun hedef)');
      await confirmTyped(tester, 'DEVRET');
      noException(tester, 'devir kodu');
    },
    'acil sıfırlama sonucu (uyarılar + tek seferlik gizli değerler)': (tester, size) async {
      final env = e2Env(role: null, globalRole: 'super_user');
      env.cloud.emergencyResetToReturn = const EmergencyResetResult(
        action: 'UNCLAIMED',
        deviceUuid: uid,
        affectedUsersCount: 3,
        setupPin: '123456',
        localKey: 'ornek-yerel-anahtar-12345678',
        warnings: <String>[
          'Yerel anahtar cihaza iletilemedi; çok uzun bir uyarı metni: cihazı yerinde yeniden anahtarlayın ve sonucu doğrulayın.',
          'Çocuk kilidi sıfırlanamadı.',
        ],
        partial: true,
      );
      await open<void>(tester, env, size, (c) => TransferOwnershipDialog.show(c));
      noException(tester, 'açılış');
      await typeInto(tester, 'field_reset_uid', uid);
      await typeInto(tester, 'field_reset_reason', 'Kiracı tahliye edildi, sözleşme ibraz edildi.');
      await typeInto(tester, 'field_reset_new_owner', longEmail);
      await tapVisible(tester, 'btn_reset_submit');
      noException(tester, 'yazarak onay penceresi');
      await confirmTyped(tester, uid);
      noException(tester, 'sonuç görünümü');
      expect(find.byKey(const Key('emergency_result')), findsOneWidget);
    },
    'cihaz eşleştirme (servis personeli, müşteri + OTP + uyarılar)': (tester, size) async {
      final env = e2Env(role: null, globalRole: 'service_user');
      env.cloud.claimResultToReturn = ClaimResult(
        homeId: kHomeA,
        homeName: 'Çok Uzun Bir Daire Adı Ve Çok Uzun Bir Sokak Adı Daire 14',
        deviceUuid: uid,
        customerAccount: const CustomerAccountInfo(created: true, inviteSent: false, status: 'pending_invite'),
        technicianAccessExpiresAt: DateTime.utc(2026, 10, 4, 12),
        warnings: const <String>['Müşteriye davet e-postası gönderilemedi; çok uzun bir uyarı metni: şifre sıfırlama bağlantısı gönderin.'],
      );
      await open<bool>(tester, env, size, (c) => ClaimManualDialog.show(c));
      noException(tester, 'açılış (müşteri bölümü açık)');
      await typeInto(tester, 'field_claim_uid', uid);
      await typeInto(tester, 'field_claim_pin', '482916');
      await typeInto(tester, 'field_claim_customer', longEmail);
      await tapVisible(tester, 'btn_claim_send_otp');
      noException(tester, 'OTP gönderildi (kilitli alanlar)');
      await typeInto(tester, 'field_claim_otp', '135790');
      await tapVisible(tester, 'btn_claim_submit');
      noException(tester, 'başarı + uyarılar');
    },
    'servis PIN ile giriş': (tester, size) async {
      final env = e2Env(authenticated: false);
      await open<void>(tester, env, size, (c) => ServicePinDialog.show(c));
      noException(tester, 'açılış');
      await tapVisible(tester, 'btn_service_login');
      noException(tester, 'doğrulama hataları');
    },
    'yazarak onay penceresi': (tester, size) async {
      final env = e2Env();
      await open<bool>(
        tester,
        env,
        size,
        (c) => ConfirmDestructiveDialog.show(
          c,
          title: 'Cihaz Kalıcı Olarak Silinsin mi?',
          message: 'Bu işlem geri alınamaz. Cihaza bağlı tüm kullanıcıların erişimi, kurulum kayıtları ve geçmiş çok uzun bir '
              'açıklama metniyle birlikte kalıcı olarak silinecek; devam etmek için ifadeyi yazın.',
          confirmPhrase: 'AHBU-S3-1A2B3C',
        ),
      );
      noException(tester, 'açılış');
      await typeInto(tester, 'field_confirm_phrase', 'AHBU');
      noException(tester, 'ifade yazılıyor');
    },
    // --- hata / bekleme / uyarı durumları (uzun Türkçe iletiler, geri sayımlı düğmeler, yan eylemler) ---
    'giriş sayfası (hata + hız sınırı geri sayımı)': (tester, size) async {
      final env = e2Env(authenticated: false);
      env.cloud.loginError = apiError(
        429,
        'Çok fazla giriş denemesi yapıldı. Güvenliğiniz için lütfen biraz bekleyip yeniden deneyin.',
        code: 'RATE_LIMITED',
        retryAfter: const Duration(seconds: 45),
      );
      await pumpApp(tester, state: env.state, size: size, child: const LoginPage());
      await settle(tester);
      await typeInto(tester, 'field_email', 'ayse@ornek.test');
      await typeInto(tester, 'field_password', 'ornek-parola-1234');
      await tapVisible(tester, 'btn_login');
      noException(tester, 'hata + geri sayım düğmesi');
      expect(find.byKey(const Key('login_error')), findsOneWidget);
    },
    'kayıt sayfası (sunucu hatası)': (tester, size) async {
      final env = e2Env(authenticated: false);
      env.cloud.registerError = apiError(409, 'Bu e-posta adresiyle zaten bir hesap var. Giriş yapmayı veya şifrenizi sıfırlamayı deneyin.', code: 'CONFLICT');
      await pumpApp(tester, state: env.state, size: size, child: const RegisterPage());
      await settle(tester);
      await typeInto(tester, 'field_full_name', longName);
      await typeInto(tester, 'field_email', longEmail);
      await typeInto(tester, 'field_phone', '05551112233');
      await typeInto(tester, 'field_password', 'ornek-parola-1234');
      await typeInto(tester, 'field_password_confirm', 'ornek-parola-1234');
      await tapVisible(tester, 'btn_register_submit');
      noException(tester, 'sunucu hatası');
    },
    'aile listesi (yükleme hatası + yeniden dene)': (tester, size) async {
      final env = e2Env();
      env.cloud.membersError = apiError(0, 'Sunucuya ulaşılamadı. İnternet bağlantınızı kontrol edip tekrar deneyin.', code: 'NETWORK');
      await pumpApp(tester, state: env.state, size: size, child: const FamilyMembersPage());
      await settle(tester);
      noException(tester, 'hata kartı + Tekrar Dene');
      expect(find.byKey(const Key('members_error')), findsOneWidget);
    },
    'eve katıl (geçersiz kod hatası)': (tester, size) async {
      final env = e2Env(role: null);
      env.cloud.previewError = apiError(404, 'Bu kod geçersiz veya süresi dolmuş. Lütfen kodu kontrol edip yeniden deneyin.', code: 'NOT_FOUND');
      await open<bool>(tester, env, size, (c) => JoinHomeDialog.show(c));
      await typeInto(tester, 'field_join_code', 'AHBU-AB12CD34EF');
      await tapVisible(tester, 'btn_join_continue');
      noException(tester, 'hata');
    },
    'hesabı sil (tek sahip olunan daireler)': (tester, size) async {
      final env = e2Env(role: 'owner');
      env.cloud.deleteAccountError = apiError(
        409,
        'Bazı dairelerin tek sahibisiniz.',
        code: 'SOLE_OWNER',
        details: <String, dynamic>{
          'homes': <Map<String, dynamic>>[
            <String, dynamic>{'id': kHomeA, 'name': 'Çok Uzun Bir Daire Adı Ve Çok Uzun Bir Sokak Adı Daire 14', 'other_member_count': 12, 'device_count': 3},
            <String, dynamic>{'id': kHomeB, 'name': 'Yazlık'},
          ],
        },
      );
      await open<void>(tester, env, size, (c) => DeleteAccountDialog.show(c));
      await typeInto(tester, 'field_delete_password', 'ornek-parola-1234');
      await typeInto(tester, 'field_delete_confirm', 'SİL');
      await tapVisible(tester, 'btn_delete_account');
      noException(tester, 'tek sahip listesi + devir yönlendirmesi');
      expect(find.byKey(const Key('sole_owner_notice')), findsOneWidget);
    },
    'cihaz eşleştirme (PIN kilidi: bekleme sayacı)': (tester, size) async {
      final env = e2Env();
      env.cloud.claimError = apiError(423, 'Cihaz geçici olarak kilitlendi.', code: 'PIN_LOCKED', retryAfter: const Duration(seconds: 90));
      await open<bool>(tester, env, size, (c) => ClaimManualDialog.show(c));
      await typeInto(tester, 'field_claim_uid', uid);
      await typeInto(tester, 'field_claim_pin', '482916');
      await tapVisible(tester, 'btn_claim_submit');
      noException(tester, 'kilit bildirimi + geri sayım düğmesi');
      expect(find.byKey(const Key('claim_lock_notice')), findsOneWidget);
    },
    'servis PIN ile giriş (hatalı PIN)': (tester, size) async {
      final env = e2Env(authenticated: false);
      env.cloud.serviceLoginError = apiError(401, 'Servis PIN\'i geçersiz veya süresi dolmuş. Ev sahibinden yeni bir PIN isteyin.', code: 'INVALID_CREDENTIALS', remaining: 3);
      await open<void>(tester, env, size, (c) => ServicePinDialog.show(c));
      await typeInto(tester, 'field_service_pin', '123456');
      await typeInto(tester, 'field_service_technician', longName);
      await tapVisible(tester, 'btn_service_login');
      noException(tester, 'hata');
    },
    'biyometrik istem (doğrulama başarısız geri bildirimi)': (tester, size) async {
      final env = e2Env(biometric: FakeBiometric(supported: true, authResult: false, label: 'Yüz Tanıma / Parmak İzi'));
      env.state.setBiometricForTesting(isSupported: true);
      await open<bool>(tester, env, size, (c) => BiometricPromptDialog.show(c, label: 'Yüz Tanıma / Parmak İzi'));
      await tapVisible(tester, 'btn_biometric_enable');
      noException(tester, 'başarısızlık geri bildirimi');
    },
    'çıkış onayı': (tester, size) async {
      final env = e2Env();
      await open<void>(tester, env, size, (c) => confirmAndLogout(c, env.state));
      noException(tester, 'onay penceresi');
      expect(find.byKey(const Key('btn_logout_confirm')), findsOneWidget);
    },
    'karekod tarayıcı (desteklenmeyen platform ekranı)': (tester, size) async {
      final env = e2Env(role: null, authenticated: false);
      await open<String>(
        tester,
        env,
        size,
        (c) => Navigator.of(c).push<String>(
          MaterialPageRoute(builder: (_) => QrScannerPage(supportedOverride: false, onManualFallback: () {})),
        ),
      );
      noException(tester, 'açılış');
      expect(find.byKey(const Key('scanner_unsupported_title')), findsOneWidget);
    },
  };

  for (final config in configs) {
    final size = config.$1;
    final scale = config.$2;
    group('${size.width.toInt()}x${size.height.toInt()} ekran, yazı ölçeği $scale', () {
      for (final entry in scenarios.entries) {
        testWidgets('${entry.key}: taşma ve çizim istisnası yok; eylemlere ulaşılabilir', (tester) async {
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          collected.clear();
          final original = FlutterError.onError;
          FlutterError.onError = (details) {
            collected.add(details.toString());
            original?.call(details);
          };
          addTearDown(() => FlutterError.onError = original);
          await entry.value(tester, size);
          noException(tester, 'son durum');
        });
      }
    });
  }
}
