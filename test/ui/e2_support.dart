import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/ui/common/inline_message.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/support.dart';

/// WP-E2 (kimlik, aile, claim, Wi-Fi kurtarma) arayüz testleri için ortak yardımcılar.

const String kUserId = '99999999-9999-4999-8999-999999999999';
const String kOtherUserId = '88888888-8888-4888-8888-888888888888';
const String kUserEmail = 'ayse@ornek.test';
const String kUserPhone = '05551112233';
const String kStrongPassword = 'dogru-parola-1234';

/// `FakeCloudApi` + E2 arayüzünün kullandığı ek uçlar. Her çağrı `calls` listesine yazılır
/// (gizli değerler yazılmaz: yalnızca yöntem adı ve gerekirse kimlik).
class E2Cloud extends FakeCloudApi {
  E2Cloud({super.clock});

  int _sessions = 0;

  UserModel registeredUser = const UserModel(id: kUserId, email: kUserEmail, fullName: 'Ayşe Yılmaz');

  /// Sahte oturum açar ve sunucu yanıtı şeklinde yük döndürür.
  Map<String, dynamic> openSession(UserModel user) {
    _sessions++;
    beginSession(accessToken: 'e2-access-$_sessions', refreshToken: 'e2-refresh-$_sessions');
    return <String, dynamic>{
      'access_token': 'e2-access-$_sessions',
      'refresh_token': 'e2-refresh-$_sessions',
      'user': user.toJson(),
    };
  }

  // --- giriş ---
  /// `login` çağrılarının (kimlik, parola uzunluğu, parolada baş/son boşluk var mı) kaydı.
  final List<Map<String, Object?>> loginArgs = <Map<String, Object?>>[];

  /// Doğrulanan son parola (yalnızca testte karşılaştırmak için; loglanmaz).
  String? lastLoginPassword;

  @override
  Future<Map<String, dynamic>> login(String identifier, String password) async {
    loginArgs.add(<String, Object?>{
      'identifier': identifier,
      'passwordLength': password.length,
      'passwordEdgeSpace': password != password.trim(),
    });
    lastLoginPassword = password;
    return super.login(identifier, password);
  }

  // --- kayıt / sosyal giriş ---
  Object? registerError;
  Completer<void>? registerGate;
  final List<Map<String, Object?>> registerArgs = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> register({
    required String fullName,
    required String email,
    required String password,
    String? phone,
  }) async {
    calls.add('register');
    registerArgs.add(<String, Object?>{
      'fullName': fullName,
      'email': email,
      'passwordLength': password.length,
      'passwordEdgeSpace': password != password.trim(),
      'phone': phone,
    });
    final gate = registerGate;
    if (gate != null) await gate.future;
    final error = registerError;
    if (error != null) throw error;
    return openSession(registeredUser);
  }

  Object? googleError;
  final List<String> googleTokens = <String>[];

  @override
  Future<Map<String, dynamic>> loginWithGoogle({required String idToken}) async {
    calls.add('loginWithGoogle');
    googleTokens.add(idToken);
    final error = googleError;
    if (error != null) throw error;
    return openSession(registeredUser);
  }

  Object? appleError;
  final List<Map<String, String?>> appleArgs = <Map<String, String?>>[];

  @override
  Future<Map<String, dynamic>> loginWithApple({
    required String identityToken,
    String? fullName,
    String? nonce,
  }) async {
    calls.add('loginWithApple');
    appleArgs.add(<String, String?>{'fullName': fullName, 'nonce': nonce});
    final error = appleError;
    if (error != null) throw error;
    return openSession(registeredUser);
  }

  // --- telefon OTP ---
  CodeChallenge otpChallenge = const CodeChallenge(
    message: 'Doğrulama kodu gönderildi.',
    expiresIn: Duration(minutes: 5),
    resendAfter: Duration(seconds: 45),
  );
  Object? otpSendError;
  Object? otpVerifyError;
  Completer<void>? otpSendGate;
  final List<String> otpPhones = <String>[];

  @override
  Future<CodeChallenge> sendPhoneOtp(String phone) async {
    calls.add('sendPhoneOtp');
    otpPhones.add(phone);
    final gate = otpSendGate;
    if (gate != null) await gate.future;
    final error = otpSendError;
    if (error != null) throw error;
    return otpChallenge;
  }

  @override
  Future<Map<String, dynamic>> verifyPhoneOtp(String phone, String code) async {
    calls.add('verifyPhoneOtp');
    final error = otpVerifyError;
    if (error != null) throw error;
    return openSession(registeredUser);
  }

  // --- şifre sıfırlama ---
  CodeChallenge forgotChallenge = const CodeChallenge(
    message: 'Hesap kayıtlıysa kod gönderildi.',
    expiresIn: Duration(minutes: 10),
    resendAfter: Duration(seconds: 60),
  );
  Object? forgotError;
  final List<String> forgotIdentifiers = <String>[];
  Object? resetError;
  Completer<void>? resetGate;

  /// Sıfırlama yanıtı oturum taşısın mı (sunucu otomatik giriş yapsın mı).
  bool resetReturnsSession = false;
  final List<Map<String, Object?>> resetArgs = <Map<String, Object?>>[];

  @override
  Future<CodeChallenge> forgotPassword(String identifier) async {
    calls.add('forgotPassword');
    forgotIdentifiers.add(identifier);
    final error = forgotError;
    if (error != null) throw error;
    return forgotChallenge;
  }

  @override
  Future<Map<String, dynamic>> resetPassword({
    String? identifier,
    String? code,
    String? token,
    required String newPassword,
  }) async {
    calls.add('resetPassword');
    resetArgs.add(<String, Object?>{
      'identifier': identifier,
      'code': code,
      'hasToken': token != null,
      'passwordLength': newPassword.length,
    });
    final gate = resetGate;
    if (gate != null) await gate.future;
    final error = resetError;
    if (error != null) throw error;
    if (resetReturnsSession) return openSession(registeredUser);
    return <String, dynamic>{'message': 'Şifre yenilendi.'};
  }

  // --- parola / hesap ---
  final List<Map<String, Object?>> changePasswordArgs = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    calls.add('changePassword');
    changePasswordArgs.add(<String, Object?>{
      'currentLength': currentPassword.length,
      'newLength': newPassword.length,
      'newEdgeSpace': newPassword != newPassword.trim(),
    });
    final error = changePasswordError;
    if (error != null) throw error;
    return openSession(registeredUser.copyWith(mustChangePassword: false));
  }

  Object? deleteAccountError;
  Completer<void>? deleteGate;
  final List<Map<String, Object?>> deleteAccountArgs = <Map<String, Object?>>[];

  /// Başarı yanıtındaki `released_homes` (üyesiz + panosuz tek sahipli, hesapla silinen daireler; UYELIK-03).
  int deleteReleasedHomes = 0;

  @override
  Future<AccountDeletionResult> deleteAccount({String? password, String? confirm}) async {
    calls.add('deleteAccount');
    deleteAccountArgs.add(<String, Object?>{
      'hasPassword': password != null,
      'passwordLength': password?.length,
      'confirm': confirm,
    });
    final gate = deleteGate;
    if (gate != null) await gate.future;
    final error = deleteAccountError;
    if (error != null) throw error;
    return AccountDeletionResult(releasedHomes: deleteReleasedHomes);
  }

  // --- sihirli bağlantı (belirteç yalnızca sahte test değeridir) ---
  Object? magicError;
  Completer<void>? magicGate;
  final List<String> magicTokens = <String>[];

  @override
  Future<Map<String, dynamic>> magicLogin(String token) async {
    calls.add('magicLogin');
    magicTokens.add(token);
    final gate = magicGate;
    if (gate != null) await gate.future;
    final error = magicError;
    if (error != null) throw error;
    return openSession(registeredUser);
  }

  // --- aile ---
  InvitationModel? invitationToReturn;
  Object? inviteError;
  Completer<void>? inviteGate;
  final List<Map<String, Object?>> inviteArgs = <Map<String, Object?>>[];

  /// Atanırsa her çağrıyı (0 tabanlı sıra numarasıyla) kendisi yanıtlar (yarış testleri için).
  Future<InvitationModel> Function(int callIndex, String role)? inviteHandler;

  @override
  Future<InvitationModel> createInvitation(
    String homeId, {
    String role = 'resident',
    int? durationHours,
    DateTime? validFrom,
    DateTime? validUntil,
    String? guestName,
  }) async {
    calls.add('createInvitation');
    inviteArgs.add(<String, Object?>{'role': role, 'hours': durationHours, 'guestName': guestName});
    final handler = inviteHandler;
    if (handler != null) return handler(inviteArgs.length - 1, role);
    final gate = inviteGate;
    if (gate != null) await gate.future;
    final error = inviteError;
    if (error != null) throw error;
    return invitationToReturn ??
        InvitationModel(
          code: role == 'guest' ? 'AHBU-GUEST12345' : 'AHBU-FAMILY1234',
          role: role,
          expiresAt: DateTime.utc(2026, 10, 2, 12),
          guestValidUntil: role == 'guest' ? DateTime.utc(2026, 10, 1, 20, 30) : null,
        );
  }

  Object? membersError;
  Completer<void>? membersGate;
  Object? removeError;

  /// Sunucu "silindi" der ama üye listede kalır (sonucun yeniden okunarak doğrulanmasını sınar).
  bool removeKeepsMember = false;

  @override
  Future<List<HomeMember>> getHomeMembers(String homeId) async {
    final gate = membersGate;
    if (gate != null) {
      calls.add('getHomeMembers:$homeId');
      await gate.future;
    }
    final error = membersError;
    if (error != null) {
      calls.add('getHomeMembers:$homeId');
      throw error;
    }
    return super.getHomeMembers(homeId);
  }

  @override
  Future<bool> removeHomeMember(String homeId, String targetUserId) async {
    final error = removeError;
    if (error != null) {
      calls.add('removeHomeMember:$targetUserId');
      throw error;
    }
    if (removeKeepsMember) {
      calls.add('removeHomeMember:$targetUserId');
      removedMembers.add(targetUserId);
      return true;
    }
    return super.removeHomeMember(homeId, targetUserId);
  }

  Object? joinError;
  JoinHomeResult joinResult = const JoinHomeResult(homeId: kHomeA, homeName: 'Ev A', role: 'resident', message: 'Eve katıldınız.');
  final List<String> joinCodes = <String>[];

  @override
  Future<JoinHomeResult> joinHome(String code) async {
    calls.add('joinHome');
    joinCodes.add(code);
    final error = joinError;
    if (error != null) throw error;
    return joinResult;
  }

  Object? acceptError;
  final List<String> acceptCodes = <String>[];

  @override
  Future<TransferAcceptResult> acceptTransfer(String transferCode) async {
    calls.add('acceptTransfer');
    acceptCodes.add(transferCode);
    final error = acceptError;
    if (error != null) throw error;
    return const TransferAcceptResult(homeId: kHomeA, homeName: 'Ev A', message: 'Sahiplik devredildi.');
  }

  JoinCodePreview? previewToReturn;
  Object? previewError;
  final List<String> previewCodes = <String>[];

  @override
  Future<JoinCodePreview?> previewJoinCode(String code) async {
    calls.add('previewJoinCode');
    previewCodes.add(code);
    final error = previewError;
    if (error != null) throw error;
    return previewToReturn;
  }

  Map<String, dynamic>? pendingTransfer;
  Object? transferStatusError;
  Completer<void>? transferStatusGate;
  Object? initiateError;
  final List<String> initiatedTargets = <String>[];
  TransferInfo transferToReturn = TransferInfo(
    code: 'AHBU-TR-ABCDEF123456',
    expiresAt: DateTime.utc(2026, 10, 3, 12),
  );
  Object? cancelTransferError;

  @override
  Future<Map<String, dynamic>?> getTransferStatus(String homeId) async {
    calls.add('getTransferStatus');
    final gate = transferStatusGate;
    if (gate != null) await gate.future;
    final error = transferStatusError;
    if (error != null) throw error;
    return pendingTransfer;
  }

  @override
  Future<TransferInfo> initiateTransfer(String homeId, {required String targetIdentifier}) async {
    calls.add('initiateTransfer');
    initiatedTargets.add(targetIdentifier);
    final error = initiateError;
    if (error != null) throw error;
    return TransferInfo(
      code: transferToReturn.code,
      expiresAt: transferToReturn.expiresAt,
      targetIdentifier: targetIdentifier,
    );
  }

  @override
  Future<bool> cancelTransfer(String homeId) async {
    calls.add('cancelTransfer');
    final error = cancelTransferError;
    if (error != null) throw error;
    pendingTransfer = null;
    return true;
  }

  // --- claim OTP / acil sıfırlama ---
  Completer<void>? claimGate;
  final List<Map<String, Object?>> claimArgs = <Map<String, Object?>>[];

  @override
  Future<ClaimResult> claimDevice({
    required String deviceUuid,
    required String setupPin,
    String? homeName,
    String? targetOwner,
    String? otpCode,
  }) async {
    claimArgs.add(<String, Object?>{
      'uid': deviceUuid,
      'pinLength': setupPin.length,
      'homeName': homeName,
      'targetOwner': targetOwner,
      'otpLength': otpCode?.length,
    });
    final gate = claimGate;
    if (gate != null) await gate.future;
    return super.claimDevice(
      deviceUuid: deviceUuid,
      setupPin: setupPin,
      homeName: homeName,
      targetOwner: targetOwner,
      otpCode: otpCode,
    );
  }

  Object? claimOtpError;
  final List<Map<String, String>> claimOtpArgs = <Map<String, String>>[];
  Map<String, dynamic> claimOtpResponse = <String, dynamic>{'resend_after': 30};

  @override
  Future<Map<String, dynamic>> requestClaimOtp({
    required String deviceUuid,
    required String targetOwner,
  }) async {
    calls.add('requestClaimOtp');
    claimOtpArgs.add(<String, String>{'uid': deviceUuid, 'target': targetOwner});
    final error = claimOtpError;
    if (error != null) throw error;
    return Map<String, dynamic>.of(claimOtpResponse);
  }

  Object? emergencyError;
  final List<Map<String, Object?>> emergencyArgs = <Map<String, Object?>>[];

  @override
  Future<EmergencyResetResult> emergencyResetDevice({
    required String deviceUuid,
    required String confirmUid,
    required String reason,
    String? newOwnerIdentifier,
  }) async {
    calls.add('emergencyResetDevice');
    emergencyArgs.add(<String, Object?>{
      'uid': deviceUuid,
      'confirm': confirmUid,
      'reasonLength': reason.length,
      'newOwner': newOwnerIdentifier,
    });
    final error = emergencyError;
    if (error != null) throw error;
    return emergencyResetToReturn ?? EmergencyResetResult(action: 'UNCLAIMED', deviceUuid: deviceUuid);
  }
}

/// Test ortamı: durum + sahte bulut.
class E2Env {
  E2Env(this.h, this.cloud);

  final StateHarness h;
  final E2Cloud cloud;

  AutomationState get state => h.state;
  FakeClock get clock => h.clock;
}

/// Giriş yapmış kullanıcı + aktif ev ([role] verilirse). Ağ yok: durum elle kurulur.
E2Env e2Env({
  String? role = 'owner',
  String globalRole = 'user',
  bool authenticated = true,
  HomeModel? home,
  String email = kUserEmail,
  String phone = kUserPhone,
  FakeBiometric? biometric,
  bool autoInit = false,
  FakeStorage? storage,
  Map<String, Object> prefs = const <String, Object>{},
}) {
  SharedPreferences.setMockInitialValues(<String, Object>{...prefs});
  final clock = FakeClock();
  final cloud = E2Cloud(clock: clock);
  final h = StateHarness(clock: clock, cloud: cloud, biometric: biometric, autoInit: autoInit, storage: storage);
  if (authenticated && !autoInit) {
    h.state
      ..setCurrentUserForTesting(
        UserModel(id: kUserId, email: email, fullName: 'Ayşe Yılmaz', phone: phone, role: globalRole),
      )
      ..setAuthStatusForTesting(AuthStatus.authenticated);
    if (role != null || home != null) {
      final active = home ?? testHome(role: role!);
      h.state.setHomesForTesting(<HomeModel>[active], activeHome: active);
    }
  } else if (!autoInit) {
    // Oturumsuz (açılışı bitmiş) durum: `checking` yalnızca açılış/biyometrik kilit sürerken geçerlidir.
    h.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
  }
  addTearDown(h.dispose);
  return E2Env(h, cloud);
}

/// Zamanlı animasyonları ilerletir (sonsuz animasyonlu göstergelerle `pumpAndSettle` takılır).
Future<void> settle(WidgetTester tester, {int frames = 4}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
  await tester.pump();
}

/// Bir diyaloğu/sayfayı bir düğmeyle açar ve kapanış sonucunu yakalar.
class Opened<T> {
  T? result;
  bool done = false;
}

Future<Opened<T>> openFromHost<T>(
  WidgetTester tester,
  AutomationState state,
  Future<T?> Function(BuildContext context) show, {
  Size size = const Size(800, 1400),
  ThemeMode themeMode = ThemeMode.dark,
}) async {
  final opened = Opened<T>();
  await pumpApp(
    tester,
    state: state,
    size: size,
    themeMode: themeMode,
    child: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            key: const Key('open_host'),
            onPressed: () {
              show(context).then((value) {
                opened.result = value;
                opened.done = true;
              });
            },
            child: const Text('Aç'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const Key('open_host')));
  await settle(tester);
  return opened;
}

/// Verilen anahtarlı alana metin yazar ve çerçeveyi ilerletir.
Future<void> typeInto(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: 'alan bulunamadı: $key');
  await tester.ensureVisible(finder);
  await tester.enterText(finder, text);
  await tester.pump();
}

/// Anahtarlı düğmeye dokunur.
Future<void> tapKey(WidgetTester tester, String key, {bool settleAfter = true}) async {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: 'düğme bulunamadı: $key');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  if (settleAfter) await settle(tester);
}

/// Görünür metne sahip öğeye dokunur (ör. sekme başlıkları: anahtar `Tab` üzerinde isabet almaz).
Future<void> tapText(WidgetTester tester, String text, {bool settleAfter = true}) async {
  final finder = find.text(text);
  expect(finder, findsOneWidget, reason: 'metin bulunamadı: $text');
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  if (settleAfter) await settle(tester);
}

/// Anahtarlı metin alanının salt-okunur (kilitli) olup olmadığı.
bool isReadOnly(WidgetTester tester, String key) => tester
    .widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)))
    .readOnly;

/// Anahtarlı metin alanındaki metin.
String fieldText(WidgetTester tester, String key) => tester
    .widget<EditableText>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(EditableText)))
    .controller
    .text;

/// Anahtarlı widget'ın görünür metni.
String textOf(WidgetTester tester, String key) {
  final finder = find.byKey(Key(key));
  expect(finder, findsOneWidget, reason: 'metin bulunamadı: $key');
  final widget = tester.widget(finder);
  if (widget is Text) return widget.data ?? widget.textSpan?.toPlainText() ?? '';
  if (widget is SelectableText) return widget.data ?? '';
  if (widget is InlineMessage) return widget.message;
  return '';
}

/// `ApiException` kısayolları.
ApiException apiError(int status, String message, {String? code, Duration? retryAfter, Duration? resendAfter, int? remaining, Map<String, dynamic>? details}) =>
    ApiException(
      statusCode: status,
      message: message,
      code: code,
      retryAfter: retryAfter,
      resendAfter: resendAfter,
      remainingAttempts: remaining,
      details: details,
    );
