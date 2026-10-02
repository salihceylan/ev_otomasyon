import 'dart:io';

import 'package:ev_otomasyon/services/board_network_binding.dart';
import 'package:flutter_test/flutter_test.dart';

/// Dart <-> Android yerel taraf SÖZLEŞME KAYMASI bekçisi (WP-NET). Gerçek cihaz/emülatör YOK: yalnız kaynak taraması.
///
/// Yerel Kotlin kodu `flutter test` ile çalışmaz (JVM testleri: `cd android && ./gradlew :app:testDebugUnitTest`);
/// bu yüzden iki tarafı birbirine bağlayan, sessizce bozulabilecek yerler burada kilitlenir:
///  * `MainActivity.configureFlutterEngine` eklentiyi KAYDEDİYOR mu (başka bir yama bu satırı kaybederse özellik
///    sessizce kapanır: `MissingPluginException` -> `unsupported`),
///  * manifestte iki izin var mı (`ACCESS_NETWORK_STATE`, `CHANGE_NETWORK_STATE`),
///  * kanal adı, yöntem adları, argüman anahtarları ve `status` metinleri iki tarafta AYNI mı,
///  * Dart üst sınırı (`nativeGrace`) yerelin en kötü yanıt süresinden (GRACE / bekçi payı) büyük mü.
const String _kotlinDir = 'android/app/src/main/kotlin/com/ahbu/evotomasyon/ev_otomasyon';

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path bulunamadı (flutter test proje kökünden çalışmalı)');
  return file.readAsStringSync();
}

/// Kotlin satır/blok yorumlarını atar (yorum satırına alınmış kod "var" sayılmasın).
String _stripKotlinComments(String source) =>
    source.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '').replaceAll(RegExp(r'//[^\n]*'), '');

String _stripXmlComments(String source) => source.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

void main() {
  late String mainActivity;
  late String manifest;
  late String plugin;
  late String core;
  late String dartBinding;

  setUpAll(() {
    mainActivity = _stripKotlinComments(_read('$_kotlinDir/MainActivity.kt'));
    manifest = _stripXmlComments(_read('android/app/src/main/AndroidManifest.xml'));
    plugin = _stripKotlinComments(_read('$_kotlinDir/BoardNetworkPlugin.kt'));
    core = _stripKotlinComments(_read('$_kotlinDir/BoardNetworkCore.kt'));
    dartBinding = _read('lib/services/board_network_binding.dart');
  });

  group('yerel eklenti kaydı kaybolmamalı (birleştirme/yama güvencesi)', () {
    test('MainActivity.configureFlutterEngine: super çağrısından SONRA BoardNetworkPlugin eklenir', () {
      final declaration = mainActivity.indexOf(RegExp(r'override\s+fun\s+configureFlutterEngine\s*\(\s*flutterEngine\s*:\s*FlutterEngine\s*\)'));
      expect(declaration, isNonNegative, reason: 'configureFlutterEngine geçersiz kılınmamış: eklenti HİÇ kaydedilmez');
      final superCall = mainActivity.indexOf('super.configureFlutterEngine(flutterEngine)', declaration);
      final register = mainActivity.indexOf('flutterEngine.plugins.add(BoardNetworkPlugin())', declaration);
      expect(superCall, isNonNegative, reason: 'super çağrısı yok: GeneratedPluginRegistrant eklentileri kaydedilmez');
      expect(register, isNonNegative, reason: 'BoardNetworkPlugin kaydı yok: özellik sessizce kapanır');
      expect(register, greaterThan(superCall));
      expect(mainActivity, contains('import io.flutter.embedding.engine.FlutterEngine'));
    });

    test('AndroidManifest: ACCESS_NETWORK_STATE ve CHANGE_NETWORK_STATE izinleri var (normal izinler)', () {
      for (final permission in <String>['android.permission.ACCESS_NETWORK_STATE', 'android.permission.CHANGE_NETWORK_STATE']) {
        expect(
          RegExp('<uses-permission\\s+android:name="${RegExp.escape(permission)}"').hasMatch(manifest),
          isTrue,
          reason: '$permission manifestte yok (CHANGE_NETWORK_STATE yoksa acquire permission_denied olur)',
        );
      }
    });
  });

  group('kanal sözleşmesi: Dart ile Kotlin birebir', () {
    String kotlinConst(String source, String name) {
      final match = RegExp('const val ${RegExp.escape(name)}\\s*=\\s*"([^"]*)"').firstMatch(source);
      expect(match, isNotNull, reason: '$name Kotlin kaynağında bulunamadı');
      return match!.group(1)!;
    }

    test('kanal adı', () {
      expect(kotlinConst(plugin, 'CHANNEL_NAME'), AndroidBoardNetworkBinding.channelName);
    });

    test('yöntem adları: acquire / release / status / networkLost', () {
      expect(kotlinConst(plugin, 'METHOD_ACQUIRE'), 'acquire');
      expect(kotlinConst(plugin, 'METHOD_RELEASE'), 'release');
      expect(kotlinConst(plugin, 'METHOD_STATUS'), 'status');
      expect(kotlinConst(plugin, 'METHOD_NETWORK_LOST'), 'networkLost');
      // Dart tarafı aynı metinleri kullanıyor (status çağrılmaz).
      expect(dartBinding, contains("'acquire'"));
      expect(dartBinding, contains("'release'"));
      expect(dartBinding, contains("'networkLost'"));
    });

    test('acquire argüman anahtarları: subnet + timeoutMs', () {
      expect(plugin, contains('call.argument<Any>("subnet")'));
      expect(plugin, contains('call.argument<Any>("timeoutMs")'));
      expect(dartBinding, contains("'subnet': subnet"));
      expect(dartBinding, contains("'timeoutMs': timeout.inMilliseconds"));
    });

    test('acquire durum metinleri (8) iki tarafta AYNI; release durumları ayrı', () {
      final block = RegExp(r'object\s+BoardNetworkStatus\s*\{([\s\S]*?)\n\}').firstMatch(core);
      expect(block, isNotNull, reason: 'Kotlin BoardNetworkStatus nesnesi bulunamadı');
      final all = <String, String>{
        for (final m in RegExp(r'const val (\w+)\s*=\s*"([^"]*)"').allMatches(block!.group(1)!)) m.group(1)!: m.group(2)!,
      };
      expect(all['RELEASED'], 'released');
      expect(all['NOT_BOUND'], 'not_bound');
      final acquireStatuses = all.entries.where((e) => e.key != 'RELEASED' && e.key != 'NOT_BOUND').map((e) => e.value).toSet();
      expect(acquireStatuses, BoardNetworkStatus.values.map((s) => s.wire).toSet(), reason: 'Kotlin ve Dart durum kümeleri aynı olmalı');
    });

    test('bind_denied ayrıntısı iki tarafta aynı', () {
      expect(kotlinConst(core, 'DETAIL_BIND_DENIED'), BoardNetworkLease.bindDeniedDetail);
    });
  });

  group('süre bütçesi: Dart üst sınırı yerelin en kötü yanıtından büyük', () {
    int kotlinMillis(String name) {
      final match = RegExp('const val ${RegExp.escape(name)}\\s*=\\s*([0-9_]+)L').firstMatch(core);
      expect(match, isNotNull, reason: '$name Kotlin kaynağında bulunamadı');
      return int.parse(match!.group(1)!.replaceAll('_', ''));
    }

    test('nativeGrace > GRACE_MS ve > WATCHDOG_MARGIN_MS (yerel en geç timeoutMs + GRACE_MS sonra yanıt verir)', () {
      final graceMs = kotlinMillis('GRACE_MS');
      final watchdogMs = kotlinMillis('WATCHDOG_MARGIN_MS');
      final dartGraceMs = AndroidBoardNetworkBinding.defaultNativeGrace.inMilliseconds;
      expect(dartGraceMs, greaterThan(graceMs), reason: 'yoksa geç ama doğru yerel sonuç yanlışlıkla "timeout" olur');
      expect(dartGraceMs, greaterThan(watchdogMs));
    });
  });
}
