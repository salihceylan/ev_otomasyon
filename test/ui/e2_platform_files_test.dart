import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Platform yapılandırma dosyalarının **statik** taraması (iOS Windows'ta derlenemez; yapılandırma
/// anahtarları dosya içeriğiyle doğrulanır). Bu testler güvenlik kararlarını (release'te cleartext
/// genel olarak kapalı + yalnızca pano adresleri için dar istisna, yedekleme kapalı, açık INTERNET izni)
/// ve yerel kimlik doğrulama gereksinimlerini kilitler.
void main() {
  String read(String path) {
    final file = File(path);
    if (!file.existsSync()) throw TestFailure('dosya yok: $path');
    return file.readAsStringSync();
  }

  /// XML yorumlarını atar (yorum içindeki anahtar sözcükler yanıltmasın).
  String stripXmlComments(String xml) => xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  group('Android ana manifest (release dahil tüm derlemeler)', () {
    late String manifest;
    setUpAll(() => manifest = stripXmlComments(read('android/app/src/main/AndroidManifest.xml')));

    test('AÇIK internet izni vardır (yalnızca debug/profile manifestine bırakılmamıştır)', () {
      expect(manifest, contains('android.permission.INTERNET'));
    });

    test('allowBackup kapalıdır', () {
      expect(manifest, contains('android:allowBackup="false"'));
    });

    test('düz HTTP (cleartext) release manifestinde genel olarak açık DEĞİLDİR; dar ağ güvenlik yapılandırması bağlıdır', () {
      expect(manifest, isNot(contains('usesCleartextTraffic="true"')));
      expect(manifest, contains('android:networkSecurityConfig="@xml/network_security_config"'));
      expect(manifest, isNot(contains('android:debuggable="true"')));
    });

    test('kamera izni ve isteğe bağlı kamera özelliği korunur', () {
      expect(manifest, contains('android.permission.CAMERA'));
      expect(manifest, contains('android.hardware.camera" android:required="false"'));
    });

    test('derin bağlantı: yalnızca https + üretim ana makinesi + bilinen yollar', () {
      expect(manifest, contains('android:scheme="https"'));
      expect(manifest, contains('android:host="evotomasyon.gudeteknoloji.com.tr"'));
      for (final path in <String>['/reset-password', '/magic-login', '/claim']) {
        expect(manifest, contains('android:pathPrefix="$path"'));
      }
      expect(manifest, contains('android.intent.category.BROWSABLE'));
      // Şema yalnızca https: düz http bağlantısı yakalanmaz.
      expect(RegExp(r'android:scheme="http"').hasMatch(manifest), isFalse);
    });
  });

  group('Android ağ güvenlik yapılandırması (release)', () {
    late String config;
    setUpAll(() => config = stripXmlComments(read('android/app/src/main/res/xml/network_security_config.xml')));

    test('varsayılan olarak düz HTTP kapalıdır ve yalnızca sistem sertifika otoriteleri güvenilir', () {
      expect(RegExp(r'<base-config\s+cleartextTrafficPermitted="false"').hasMatch(config), isTrue);
      expect(config, contains('<certificates src="system"'));
      expect(config, isNot(contains('src="user"')), reason: 'kullanıcı sertifikalarına güvenilmez');
    });

    test('düz HTTP istisnası YALNIZCA pano adresleriyle sınırlıdır (AP 192.168.4.1, *.local, localhost)', () {
      final domains = RegExp(r'<domain[^>]*>([^<]+)</domain>').allMatches(config).map((m) => m.group(1)!.trim()).toSet();
      expect(domains, <String>{'192.168.4.1', 'local', 'localhost'});
      // `cleartextTrafficPermitted="true"` yalnızca domain-config içinde geçer (base-config'te değil).
      final trueCount = RegExp('cleartextTrafficPermitted="true"').allMatches(config).length;
      final inDomainConfig = RegExp(r'<domain-config\s+cleartextTrafficPermitted="true"').allMatches(config).length;
      expect(trueCount, inDomainConfig);
    });

    test('debug yapılandırması release dosyasını yalnızca debug derlemesinde geçersiz kılar', () {
      final debugConfig = stripXmlComments(read('android/app/src/debug/res/xml/network_security_config.xml'));
      expect(RegExp(r'<base-config\s+cleartextTrafficPermitted="true"').hasMatch(debugConfig), isTrue, reason: 'QA arka ucu (10.0.2.2) düz HTTP');
      expect(File('android/app/src/profile/res/xml/network_security_config.xml').existsSync(), isFalse);
    });
  });

  group('Android debug manifest', () {
    late String debug;
    setUpAll(() => debug = stripXmlComments(read('android/app/src/debug/AndroidManifest.xml')));

    test('yalnızca debug: düz HTTP QA arka ucu için cleartext açıktır', () {
      expect(debug, contains('android:usesCleartextTraffic="true"'));
      expect(debug, contains('android.permission.INTERNET'));
    });

    test('profile manifest cleartext AÇMAZ (release benzeri)', () {
      final profile = stripXmlComments(read('android/app/src/profile/AndroidManifest.xml'));
      expect(profile, isNot(contains('usesCleartextTraffic')));
    });
  });

  group('MainActivity', () {
    test('FlutterFragmentActivity kullanır (local_auth BiometricPrompt için zorunlu)', () {
      final kotlin = read('android/app/src/main/kotlin/com/ahbu/evotomasyon/ev_otomasyon/MainActivity.kt');
      expect(kotlin, contains('FlutterFragmentActivity'));
      expect(kotlin, contains('class MainActivity : FlutterFragmentActivity()'));
      expect(kotlin, isNot(contains('import io.flutter.embedding.android.FlutterActivity\n')));
    });

    test('açılış/normal temaları AppCompat tabanlıdır (local_auth Android 7-8 BiometricPrompt çökmesini önler)', () {
      for (final path in <String>[
        'android/app/src/main/res/values/styles.xml',
        'android/app/src/main/res/values-night/styles.xml',
      ]) {
        final styles = stripXmlComments(read(path));
        for (final name in <String>['LaunchTheme', 'NormalTheme']) {
          final match = RegExp('<style name="$name" parent="([^"]+)"').firstMatch(styles);
          expect(match, isNotNull, reason: '$path: $name tanımı');
          expect(match!.group(1), contains('Theme.AppCompat'), reason: '$path: $name üst teması');
        }
      }
    });
  });

  group('iOS Info.plist', () {
    late String plist;
    setUpAll(() => plist = read('ios/Runner/Info.plist'));

    /// `<key>ANAHTAR</key>` sonrasındaki `<string>` değerini döndürür.
    String? stringValue(String key) {
      final match = RegExp('<key>$key</key>\\s*<string>(.*?)</string>', dotAll: true).firstMatch(plist);
      return match?.group(1)?.trim();
    }

    /// Açıklama Türkçe karakter içeriyor mu (İngilizce/yer tutucu metin değil).
    bool looksTurkish(String? text) => text != null && RegExp('[çğıöşüÇĞİÖŞÜ]').hasMatch(text);

    test('NSFaceIDUsageDescription vardır, boş değildir ve Türkçedir (Face ID açıklaması olmadan local_auth çöker)', () {
      final text = stringValue('NSFaceIDUsageDescription');
      expect(text, isNotNull);
      expect(text, isNotEmpty);
      expect(looksTurkish(text), isTrue, reason: 'kullanıcıya gösterilen izin metni Türkçe olmalı');
    });

    test('NSLocalNetworkUsageDescription vardır ve Türkçedir; Bonjour hizmeti TANIMLI DEĞİLDİR', () {
      final text = stringValue('NSLocalNetworkUsageDescription');
      expect(text, isNotNull);
      expect(text, isNotEmpty);
      expect(looksTurkish(text), isTrue);
      expect(plist, isNot(contains('NSBonjourServices')), reason: 'cihaza doğrudan IP ile bağlanılır');
    });

    test('ATS genel olarak kapatılmaz; yalnızca yerel ağ HTTP\'sine izin verilir', () {
      expect(plist, isNot(contains('NSAllowsArbitraryLoads')));
      expect(RegExp(r'<key>NSAllowsLocalNetworking</key>\s*<true/>').hasMatch(plist), isTrue);
    });

    test('kamera izin açıklaması korunur', () {
      expect(stringValue('NSCameraUsageDescription'), isNotEmpty);
    });
  });

  group('Gizli değer taraması (yerleşik parola/anahtar yok)', () {
    test('platform dosyalarında sabit AP parolası ve API anahtarı/jeton anahtar sözcükleri bulunmaz', () {
      for (final path in <String>[
        'android/app/src/main/AndroidManifest.xml',
        'android/app/src/debug/AndroidManifest.xml',
        'ios/Runner/Info.plist',
      ]) {
        final text = read(path).toLowerCase();
        expect(text, isNot(contains('ahbu1234')), reason: '$path: sabit AP parolası');
        expect(text, isNot(contains('secret')), reason: path);
        expect(text, isNot(contains('api_key')), reason: path);
        expect(text, isNot(contains('apikey')), reason: path);
        expect(text, isNot(contains('bearer ')), reason: path);
      }
    });
  });
}
