import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Faz 2 WP-N3 (tasarım F2.C.5): bildirim kanalları ve izinler (bağımlılıksız). JVM/iOS birim testi yok; platform
/// dosyaları statik taranır (Windows'ta iOS derlenemez). Cihazda kanal ayarları ekranı kullanıcı denemesine kalır.
void main() {
  const kotlinDir = 'android/app/src/main/kotlin/com/ahbu/evotomasyon/ev_otomasyon';

  String read(String path) {
    final file = File(path);
    if (!file.existsSync()) throw TestFailure('dosya yok: $path');
    return file.readAsStringSync();
  }

  String stripComments(String source) =>
      source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '').replaceAll(RegExp(r'//[^\n]*'), '');

  group('Android', () {
    test('POST_NOTIFICATIONS izni manifestte (Android 13+; pencere yalnız kullanıcı isteyince)', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml').replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      expect(RegExp(r'<uses-permission\s+android:name="android\.permission\.POST_NOTIFICATIONS"').hasMatch(manifest), isTrue);
    });

    test('NotificationChannels: üç kanal kimliği, önem ve kilit ekranı görünürlüğü', () {
      final src = stripComments(read('$kotlinDir/NotificationChannels.kt'));
      for (final id in <String>['safety_alarm', 'safety_info', 'peace_reminder']) {
        expect(src, contains('"$id"'), reason: '$id kanalı tanımlı değil');
      }
      expect(src, contains('IMPORTANCE_HIGH'));
      expect(src, contains('IMPORTANCE_DEFAULT'));
      expect(src, contains('VISIBILITY_PUBLIC'));
      expect(src, contains('VISIBILITY_PRIVATE'));
      expect(src, contains('USAGE_ALARM'), reason: 'alarm kanalı alarm sesi akışını kullanır');
      expect(src, contains('TYPE_ALARM'));
      expect(src, contains('setBypassDnd(true)'));
      expect(src, contains('Güvenlik alarmları'));
      expect(src, contains('Güvenlik bilgileri'));
      expect(src, contains('Gece hatırlatması'));
      expect(src, contains('Build.VERSION_CODES.O'), reason: 'kanallar API 26+');
      expect(src, contains('createNotificationChannel'));
    });

    test('MainActivity.onCreate kanalları oluşturur (idempotent, push gelmeden de zararsız)', () {
      final main = stripComments(read('$kotlinDir/MainActivity.kt'));
      final onCreate = main.indexOf(RegExp(r'override\s+fun\s+onCreate'));
      expect(onCreate, isNonNegative);
      expect(main.indexOf('NotificationChannels.ensure(this)', onCreate), isNonNegative);
      // Mevcut kayıtlar korunur.
      expect(main, contains('flutterEngine.plugins.add(BoardNetworkPlugin())'));
      expect(main, contains('class MainActivity : FlutterFragmentActivity()'));
    });
  });

  group('iOS', () {
    test('AppDelegate eylemsiz kategorileri kaydeder (SAFETY_ALARM, SAFETY_INFO, PEACE_CLOSE_ALL)', () {
      final swift = stripComments(read('ios/Runner/AppDelegate.swift'));
      expect(swift, contains('import UserNotifications'));
      expect(swift, contains('setNotificationCategories'));
      for (final id in <String>['SAFETY_ALARM', 'SAFETY_INFO', 'PEACE_CLOSE_ALL']) {
        expect(swift, contains('"$id"'), reason: '$id kategorisi kayıtlı değil');
      }
      expect(swift, contains('actions: []'), reason: 'bildirim eylem düğmesi bu sürümde YOK (F2-7)');
      expect(swift, isNot(contains('criticalAlert')), reason: 'kritik uyarı izni istenmez (7.2b-3)');
    });
  });
}
