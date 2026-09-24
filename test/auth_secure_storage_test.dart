import 'package:flutter_test/flutter_test.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/ev_cloud_api_service.dart';
import 'package:ev_otomasyon/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FAZ 7.1 - SecureStorage & Auth State Tests', () {
    test('UserModel toJson and fromJson roundtrip preserves all fields', () {
      final user = UserModel(
        id: 101,
        email: 'salih@gudeteknoloji.com.tr',
        fullName: 'Salih Ceylan',
        phone: '05551234567',
        role: 'owner',
        token: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.dummyToken',
      );

      final json = user.toJson();
      expect(json['id'], 101);
      expect(json['email'], 'salih@gudeteknoloji.com.tr');
      expect(json['role'], 'owner');
      expect(json['token'], user.token);

      final parsed = UserModel.fromJson(json);
      expect(parsed.id, user.id);
      expect(parsed.email, user.email);
      expect(parsed.fullName, user.fullName);
      expect(parsed.role, user.role);
      expect(parsed.token, user.token);
    });

    test('SecureStorageService graceful fallback on unit test environment', () async {
      final storage = SecureStorageService();

      // Test ortamında native kanal olmasa bile hata fırlatmadan fallback yapmalı
      expect(await storage.getAuthToken(), isNull);
      expect(await storage.getRefreshToken(), isNull);
      expect(await storage.getUser(), isNull);

      // Metotlar exception patlatmamalı
      await storage.saveAuthToken('test_token');
      await storage.saveRefreshToken('test_refresh_token');
      await storage.deleteAuthToken();
      await storage.deleteRefreshToken();
      await storage.clearAll();
    });

    test('AutomationState AuthStatus enum values and initial checking status', () {
      expect(AuthStatus.values.length, 3);
      expect(AuthStatus.values.contains(AuthStatus.checking), isTrue);
      expect(AuthStatus.values.contains(AuthStatus.authenticated), isTrue);
      expect(AuthStatus.values.contains(AuthStatus.unauthenticated), isTrue);
    });

    test('EvCloudApiService manages access and refresh tokens properly', () {
      final api = EvCloudApiService();
      expect(api.authToken, isNull);
      expect(api.currentRefreshToken, isNull);

      api.setAuthToken('access_123');
      api.setRefreshToken('refresh_456');

      expect(api.authToken, 'access_123');
      expect(api.currentRefreshToken, 'refresh_456');

      // Callback triggers on token refresh
      String? callbackAccess;
      String? callbackRefresh;
      api.onTokenRefreshed = (a, r) {
        callbackAccess = a;
        callbackRefresh = r;
      };

      api.onTokenRefreshed?.call('new_acc', 'new_ref');
      expect(callbackAccess, 'new_acc');
      expect(callbackRefresh, 'new_ref');
    });
  });
}

