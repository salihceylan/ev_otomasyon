import 'dart:convert';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/secure_storage_service.dart';
import 'package:ev_otomasyon/ui/common/confirm_dialogs.dart';
import 'package:ev_otomasyon/ui/pages/auth/login_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/support.dart';
import 'ui/e2_support.dart';

/// Oturum verisinin yalnızca güvenli depoda tutulması: belirteçler ayrı kayıtlardır, profil kaydına
/// ve tercihlere sızmaz; platform hatası yutulmaz; çıkış her şeyi siler. (Durum katmanındaki ayrıntılar
/// `test/services/automation_state_session_test.dart` içindedir; burada depo sözleşmesi ve arayüzden
/// uçtan uca giriş/çıkış doğrulanır.)
void main() {
  // Gerçek olmayan, yalnızca sızıntıyı aramak için kullanılan işaretçiler.
  const sentinelAccess = 'sentinel-access-0001';
  const sentinelRefresh = 'sentinel-refresh-0002';
  const profile = UserModel(
    id: kUserId,
    email: kUserEmail,
    fullName: 'Ayşe Yılmaz',
    phone: kUserPhone,
    role: 'service_user',
    adminNotes: 'Yönetici notu',
    mustChangePassword: true,
    emailVerified: true,
  );

  group('SecureStorageService sözleşmesi (bellek içi depo)', () {
    late FakeStorage storage;
    setUp(() => storage = FakeStorage());

    Iterable<String> entriesContaining(String text) => storage.memory.data.values.where((v) => v.contains(text));

    test('kullanıcı profili tüm alanlarıyla geri okunur', () async {
      await storage.saveUser(profile);

      final read = await storage.getUser();

      expect(read, isNotNull);
      expect(read!.id, kUserId);
      expect(read.email, kUserEmail);
      expect(read.fullName, 'Ayşe Yılmaz');
      expect(read.phone, kUserPhone);
      expect(read.role, 'service_user');
      expect(read.adminNotes, 'Yönetici notu');
      expect(read.mustChangePassword, isTrue);
      expect(read.emailVerified, isTrue);
    });

    test('belirteçler yalnızca kendi kayıtlarındadır: profil kaydında belirteç ya da parola alanı bulunmaz', () async {
      await storage.saveAuthToken(sentinelAccess);
      await storage.saveRefreshToken(sentinelRefresh);
      await storage.saveUser(profile);

      expect(entriesContaining(sentinelAccess), hasLength(1), reason: 'erişim belirteci tek kayıtta');
      expect(entriesContaining(sentinelRefresh), hasLength(1), reason: 'yenileme belirteci tek kayıtta');
      final profileRaw = entriesContaining(kUserEmail).single;
      final map = jsonDecode(profileRaw) as Map<String, dynamic>;
      for (final forbidden in <String>['token', 'access_token', 'refresh_token', 'password']) {
        expect(map.containsKey(forbidden), isFalse, reason: 'profil kaydında "$forbidden" alanı olmamalı');
        expect(profile.toJson().containsKey(forbidden), isFalse);
      }
      expect(profileRaw, isNot(contains(sentinelAccess)));
      expect(profileRaw, isNot(contains(sentinelRefresh)));
    });

    test('belirteçler ayrı ayrı silinebilir; biri silinince diğeri korunur', () async {
      await storage.saveAuthToken(sentinelAccess);
      await storage.saveRefreshToken(sentinelRefresh);

      await storage.deleteAuthToken();
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getRefreshToken(), sentinelRefresh);

      await storage.deleteRefreshToken();
      expect(storage.isEmpty, isTrue);
    });

    test('kayıt yokken okumalar null döner (hata değil)', () async {
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(await storage.getUser(), isNull);
      expect(await storage.getServiceSession(), isNull);
      expect(await storage.getLocalKey('AHBU-S3-1A2B3C'), isNull);
      expect(await storage.loadHomesCache(kUserId), isEmpty);
      expect(await storage.isBiometricEnabled(), isFalse);
    });

    test('clearAll her şeyi siler: belirteçler, profil, yerel anahtar, biyometrik bayraklar, ev önbelleği, servis oturumu', () async {
      await storage.saveAuthToken(sentinelAccess);
      await storage.saveRefreshToken(sentinelRefresh);
      await storage.saveUser(profile);
      await storage.saveBiometricEnabled(true);
      await storage.saveBiometricPromptShown(true);
      await storage.saveLocalKey('AHBU-S3-1A2B3C', 'yerel-anahtar-0003');
      await storage.saveHomesCache(kUserId, <HomeModel>[testHome()]);
      await storage.saveServiceSession(
        ServiceSessionInfo(homeId: kHomeA, homeName: 'Ev A', expiresAt: DateTime.utc(2030), technicianName: 'Teknisyen'),
      );
      expect(storage.keys, hasLength(8), reason: 'sekiz ayrı kayıt yazıldı');

      await storage.clearAll();

      expect(storage.isEmpty, isTrue);
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getUser(), isNull);
      expect(await storage.getLocalKey('AHBU-S3-1A2B3C'), isNull);
      expect(await storage.getServiceSession(), isNull);
      expect(await storage.isBiometricEnabled(), isFalse);
    });

    test('platform hatası sessizce yutulmaz: SecureStorageException fırlar ve mesaj değeri içermez', () async {
      storage.memory.failWrites = true;
      await expectLater(
        storage.saveAuthToken(sentinelAccess),
        throwsA(
          isA<SecureStorageException>()
              .having((e) => e.operation, 'operation', 'write')
              .having((e) => e.message, 'message', isNot(contains(sentinelAccess)))
              .having((e) => e.toString(), 'toString', isNot(contains(sentinelAccess))),
        ),
      );
      expect(storage.isEmpty, isTrue, reason: 'yazılamadı: kayıt oluşmadı');
      storage.memory.failWrites = false;

      await storage.saveAuthToken(sentinelAccess);
      storage.memory.failReads = true;
      await expectLater(
        storage.getAuthToken(),
        throwsA(isA<SecureStorageException>().having((e) => e.operation, 'operation', 'read')),
      );
      storage.memory.failReads = false;

      storage.memory.failDeleteAll = true;
      await expectLater(
        storage.clearAll(),
        throwsA(isA<SecureStorageException>().having((e) => e.operation, 'operation', 'deleteAll')),
      );
      expect(await storage.getAuthToken(), sentinelAccess, reason: 'silme hatasında kayıtlar olduğu gibi kalır');
    });

    test('bozuk ya da eksik profil kaydı null döner ve temizlenir (çökmez)', () async {
      for (final corrupt in <String>['{bozuk', '[1,2,3]', '{"email":"kimliksiz@ornek.test"}']) {
        await storage.saveUser(profile);
        final key = storage.keys.single;
        storage.memory.data[key] = corrupt;

        expect(await storage.getUser(), isNull, reason: 'bozuk kayıt: "$corrupt"');
        expect(storage.isEmpty, isTrue, reason: 'bozuk kayıt silinir: "$corrupt"');
      }
    });

    test('boş profil kaydı "kullanıcı yok" sayılır (çökmez)', () async {
      await storage.saveUser(profile);
      storage.memory.data[storage.keys.single] = '';

      expect(await storage.getUser(), isNull);
    });

    test('yerel anahtar cihaz kimliğinin büyük/küçük harf ve boşluk farkından etkilenmez; cihazlar birbirini etkilemez', () async {
      await storage.saveLocalKey(' ahbu-s3-1a2b3c ', 'yerel-anahtar-0001');
      await storage.saveLocalKey('AHBU-S3-FFFFFF', 'yerel-anahtar-0002');

      expect(await storage.getLocalKey('AHBU-S3-1A2B3C'), 'yerel-anahtar-0001');
      expect(await storage.getLocalKey('ahbu-s3-ffffff'), 'yerel-anahtar-0002');

      await storage.deleteLocalKey('ahbu-s3-1a2b3c');
      expect(await storage.getLocalKey('AHBU-S3-1A2B3C'), isNull);
      expect(await storage.getLocalKey('AHBU-S3-FFFFFF'), 'yerel-anahtar-0002');
    });

    test('ev önbelleği yalnızca kaydeden kullanıcıya gösterilir', () async {
      await storage.saveHomesCache(kUserId, <HomeModel>[testHome(name: 'Benim Evim')]);

      expect((await storage.loadHomesCache(kUserId)).single.name, 'Benim Evim');
      expect(await storage.loadHomesCache(kOtherUserId), isEmpty, reason: 'başka kullanıcının önbelleği gösterilmez');
    });
  });

  group('arayüzden giriş ve çıkış (durum + depo + tercihler)', () {
    testWidgets('girişte belirteçler yalnızca güvenli depoya yazılır; tercihlerde ve profil kaydında belirteç yoktur', (tester) async {
      final env = e2Env(authenticated: false);
      await pumpApp(tester, state: env.state, child: const LoginPage());

      await typeInto(tester, 'field_email', kUserEmail);
      await typeInto(tester, 'field_password', kStrongPassword);
      await tapKey(tester, 'btn_login');
      await tester.pump(const Duration(milliseconds: 50));

      expect(env.state.authStatus, AuthStatus.authenticated);
      final access = env.cloud.authToken;
      final refresh = env.cloud.currentRefreshToken;
      expect(access, isNotNull);
      expect(refresh, isNotNull);
      expect(await env.h.storage.getAuthToken(), access, reason: 'erişim belirteci güvenli depoda');
      expect(await env.h.storage.getRefreshToken(), refresh, reason: 'yenileme belirteci güvenli depoda');

      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        final value = '${prefs.get(key)}';
        expect(value, isNot(contains(access!)), reason: 'tercih "$key" erişim belirteci içermemeli');
        expect(value, isNot(contains(refresh!)), reason: 'tercih "$key" yenileme belirteci içermemeli');
      }
      final profileRaw = env.h.storage.memory.data.values.where((v) => v.contains(env.cloud.loginUser.email)).single;
      expect(profileRaw, isNot(contains(access!)));
      expect(profileRaw, isNot(contains(refresh!)));
    });

    testWidgets('onaylı çıkıştan sonra güvenli depoda ve API istemcisinde oturum verisi kalmaz; refresh belirteci sunucuda iptal edilir', (tester) async {
      final env = e2Env(authenticated: false);
      await env.state.login(kUserEmail, kStrongPassword);
      await tester.pump(const Duration(milliseconds: 50));
      final refresh = env.cloud.currentRefreshToken;
      expect(env.h.storage.isEmpty, isFalse, reason: 'giriş sonrası oturum depoda');
      expect(refresh, isNotNull);

      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('do_logout'),
                onPressed: () => confirmAndLogout(context, env.state),
                child: const Text('Çık'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'do_logout');
      await tapKey(tester, 'btn_logout_confirm');
      await tester.pump(const Duration(milliseconds: 500));

      expect(env.state.authStatus, AuthStatus.unauthenticated);
      expect(env.h.storage.isEmpty, isTrue, reason: 'güvenli depo tümüyle boş');
      expect(env.cloud.authToken, isNull);
      expect(env.cloud.currentRefreshToken, isNull);
      expect(env.cloud.revokedRefreshTokens, <String>[refresh!], reason: 'sunucuda refresh iptali');
    });

    testWidgets('vazgeçilen çıkışta depo ve oturum olduğu gibi kalır', (tester) async {
      final env = e2Env(authenticated: false);
      await env.state.login(kUserEmail, kStrongPassword);
      await tester.pump(const Duration(milliseconds: 50));
      final entriesBefore = env.h.storage.keys.length;

      await pumpApp(
        tester,
        state: env.state,
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                key: const Key('do_logout'),
                onPressed: () => confirmAndLogout(context, env.state),
                child: const Text('Çık'),
              ),
            ),
          ),
        ),
      );
      await tapKey(tester, 'do_logout');
      await tapKey(tester, 'btn_logout_cancel');

      expect(env.state.authStatus, AuthStatus.authenticated);
      expect(env.h.storage.keys, hasLength(entriesBefore));
      expect(env.cloud.revokedRefreshTokens, isEmpty);
    });
  });
}
