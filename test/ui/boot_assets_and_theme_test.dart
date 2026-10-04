import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Açılış varlıkları ve Android açılış kabuğu: **dosya okuyan** (statik) denetim (e2_platform_files_test
/// tarzı). WP-BOOT: PF-16 (varlık diyeti) ve PF-17 (NormalTheme zemini, açılış bitmap'i, referanssız dosyalar).
///
/// Burada APK/IPA boyutu ya da açılış süresi ÖLÇÜLMEZ; yalnız dosya sistemindeki gerçekler (girişler, bayt
/// sayıları, boyutlar, referanslar) kilitlenir. Cihazda native açılış görünümü ve APK boyutu kullanıcı
/// doğrulamasına kalır.
void main() {
  const res = 'android/app/src/main/res';

  String read(String path) {
    final file = File(path);
    if (!file.existsSync()) throw TestFailure('dosya yok: $path');
    return file.readAsStringSync();
  }

  String norm(String path) => path.replaceAll('\\', '/');

  /// `dizin/ad.uzantı` -> `ad`.
  String stemOf(String path) {
    final name = norm(path).split('/').last;
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  List<File> filesUnder(String dir) {
    final directory = Directory(dir);
    if (!directory.existsSync()) return <File>[];
    return directory.listSync(recursive: true).whereType<File>().toList();
  }

  String stripXmlComments(String xml) => xml.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

  bool sameBytes(File a, File b) {
    if (a.lengthSync() != b.lengthSync()) return false;
    final x = a.readAsBytesSync();
    final y = b.readAsBytesSync();
    for (var i = 0; i < x.length; i++) {
      if (x[i] != y[i]) return false;
    }
    return true;
  }

  /// `pubspec.yaml` -> `flutter:` -> `assets:` girdileri (yorum satırları atlanır).
  List<String> pubspecAssets() {
    final lines = read('pubspec.yaml').split(RegExp(r'\r?\n'));
    final start = lines.indexWhere((l) => RegExp(r'^  assets:\s*(#.*)?$').hasMatch(l));
    if (start < 0) throw TestFailure('pubspec.yaml: flutter -> assets bölümü yok');
    final entries = <String>[];
    for (final line in lines.skip(start + 1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final item = RegExp(r'''^\s{4}-\s+["']?([^"'\s#]+)["']?\s*(#.*)?$''').firstMatch(line);
      if (item == null) break; // bir sonraki bölüm başladı
      entries.add(item.group(1)!);
    }
    return entries;
  }

  /// PNG başlığından (IHDR) genişlik/yükseklik.
  ({int width, int height}) pngSize(String path) {
    final bytes = File(path).readAsBytesSync();
    const signature = <int>[137, 80, 78, 71, 13, 10, 26, 10];
    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) throw TestFailure('$path: PNG imzası yok');
    }
    final dims = ByteData.sublistView(bytes, 16, 24); // 8 imza + 4 uzunluk + 4 'IHDR'
    return (width: dims.getUint32(0), height: dims.getUint32(4));
  }

  group('pubspec varlık listesi (PF-16)', () {
    late List<String> assets;
    setUpAll(() => assets = pubspecAssets());

    test('assets: altında girdi vardır ve "/" ile biten DİZİN girişi yoktur (açık dosya listesi)', () {
      expect(assets, isNotEmpty);
      final dirs = assets.where((entry) => entry.endsWith('/')).toList();
      expect(dirs, isEmpty, reason: 'dizin girişi içindeki her dosyayı APK\'ya sokar (referanssız PNG\'ler dahil): $dirs');
    });

    test('listelenen her dosya diskte vardır ve lib/ içinde anılır', () {
      final libSource = StringBuffer();
      for (final file in filesUnder('lib').where((f) => f.path.endsWith('.dart'))) {
        libSource.write(file.readAsStringSync());
      }
      final lib = libSource.toString();
      for (final entry in assets) {
        expect(File(entry).existsSync(), isTrue, reason: '$entry diskte yok');
        expect(lib.contains(entry), isTrue, reason: '$entry lib/ içinde anılmıyor (referanssız varlık pakete girmemeli)');
      }
    });

    test('listede baytları aynı iki dosya yoktur (farklı yol = ayrı ImageCache girdisi + çift APK baytı)', () {
      final files = assets.map(File.new).toList();
      for (var i = 0; i < files.length; i++) {
        for (var j = i + 1; j < files.length; j++) {
          expect(sameBytes(files[i], files[j]), isFalse, reason: '${files[i].path} ile ${files[j].path} bayt bayt aynı');
        }
      }
    });

    test('paketlenen PNG logolar 512 px\'i aşmaz (1024² RGBA ≈ 4 MiB çözülür; en büyük kullanım 130 dp)', () {
      final pngs = assets.where((entry) => entry.toLowerCase().endsWith('.png')).toList();
      expect(pngs, isNotEmpty);
      for (final path in pngs) {
        final size = pngSize(path);
        expect(size.width, lessThanOrEqualTo(512), reason: '$path genişliği');
        expect(size.height, lessThanOrEqualTo(512), reason: '$path yüksekliği');
      }
    });

    test('assets/images/ içindeki her dosya pakete girer; referanssız tam boyutlu kopyalar assets_src/ altında durur', () {
      final listed = assets.toSet();
      final stray = filesUnder('assets/images').map((f) => norm(f.path)).where((p) => !listed.contains(p)).toList();
      expect(stray, isEmpty, reason: 'pakete girmeyen dosyalar assets_src/ altına taşınmalı (ya da pubspec listesine eklenmeli): $stray');
    });

    test('assets_src/ pakete girmez; betiklerin ana kopyaları orada durur', () {
      expect(assets.where((entry) => entry.startsWith('assets_src')), isEmpty);
      for (final master in <String>[
        'assets_src/round_app_logo.png', // betiklerin kaynağı/ana kopya (tam boyut)
        'assets_src/round_app_logo_thin_ring.png', // generate_adaptive_icons.py kaynağı
      ]) {
        expect(File(master).existsSync(), isTrue, reason: '$master yok');
        final size = pngSize(master);
        expect(size.width, greaterThan(512), reason: '$master tam boyutlu ana kopya olmalı');
      }
    });

    test('arka plan resmi üç yerde (küresel, açılış, giriş) çözümleme boyutu vermez: tek ImageCache girdisi paylaşılır', () {
      for (final path in <String>[
        'lib/ui/widgets/circuit_background.dart',
        'lib/ui/pages/auth/auth_gate.dart',
        'lib/ui/pages/auth/login_page.dart',
      ]) {
        final source = read(path);
        expect(RegExp(r'cacheWidth\s*:').hasMatch(source), isFalse, reason: path);
        expect(RegExp(r'cacheHeight\s*:').hasMatch(source), isFalse, reason: path);
        expect(source.contains('ResizeImage('), isFalse, reason: path);
      }
    });
  });

  group('Android açılış kabuğu (PF-17)', () {
    test('NormalTheme penceresi üç stil dosyasında da @color/splash_bg; üst temalar LaunchTheme ile aynı kalır', () {
      for (final dir in <String>['values', 'values-night', 'values-v31']) {
        final styles = stripXmlComments(read('$res/$dir/styles.xml'));
        final normal = RegExp(r'<style name="NormalTheme" parent="([^"]+)">(.*?)</style>', dotAll: true).firstMatch(styles);
        final launch = RegExp(r'<style name="LaunchTheme" parent="([^"]+)"').firstMatch(styles);
        expect(normal, isNotNull, reason: '$dir: NormalTheme tanımı');
        expect(launch, isNotNull, reason: '$dir: LaunchTheme tanımı');
        final background = RegExp(r'<item name="android:windowBackground">([^<]+)</item>').firstMatch(normal!.group(2)!)?.group(1);
        expect(background, '@color/splash_bg', reason: '$dir: açık/koyu gri sistem zemini yerine uygulamanın koyu laciverti');
        expect(normal.group(1), launch!.group(1), reason: '$dir: üst tema (AppCompat bağımlılığı) değişmemeli');
      }
      for (final dir in <String>['values', 'values-night']) {
        final styles = stripXmlComments(read('$res/$dir/styles.xml'));
        expect(RegExp(r'<style name="NormalTheme" parent="[^"]*Theme\.AppCompat').hasMatch(styles), isTrue, reason: '$dir: local_auth AppCompat kilidi');
      }
    });

    test('splash_bg rengi tanımlıdır (#0B1120: Flutter açılış ekranı ve genel zemin ile aynı)', () {
      final colors = stripXmlComments(read('$res/values/colors.xml'));
      expect(RegExp(r'<color name="splash_bg">#0B1120</color>').hasMatch(colors), isTrue);
    });

    test('açılış bitmap\'i yoğunluksuz (drawable-nodpi) dizindedir (Android kuralı: niteleyicisiz drawable/ mdpi sayılır ve yüksek yoğunlukta büyütülür)', () {
      final launch = read('$res/drawable/launch_background.xml');
      final names = RegExp(r'android:src="@drawable/([A-Za-z0-9_]+)"').allMatches(launch).map((m) => m.group(1)!).toSet();
      expect(names, isNotEmpty);
      for (final name in names) {
        final bitmaps = filesUnder(res).where((f) => stemOf(f.path) == name && !f.path.endsWith('.xml')).toList();
        expect(bitmaps, isNotEmpty, reason: '$name bitmap\'i yok');
        for (final file in bitmaps) {
          expect(norm(file.path), contains('/drawable-nodpi/'), reason: '${file.path}: yoğunluksuz dizinde olmalı');
        }
      }
    });

    test('splash_screen_full.* en çok 500 KB', () {
      final files = filesUnder(res).where((f) => stemOf(f.path) == 'splash_screen_full').toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        expect(file.lengthSync(), lessThanOrEqualTo(500 * 1024), reason: '${file.path} (${file.lengthSync()} B)');
      }
    });

    test('res/ altında 200 KB\'tan büyük referanssız raster dosya yoktur', () {
      const limit = 200 * 1024;
      final references = StringBuffer();
      for (final file in filesUnder(res).where((f) => f.path.endsWith('.xml'))) {
        references.write(file.readAsStringSync());
      }
      for (final file in filesUnder('android/app/src').where((f) => RegExp(r'(AndroidManifest\.xml|\.kt|\.java)$').hasMatch(f.path))) {
        references.write(file.readAsStringSync());
      }
      final text = references.toString();
      final offenders = <String>[];
      for (final file in filesUnder(res)) {
        if (!RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false).hasMatch(file.path)) continue;
        if (file.lengthSync() <= limit) continue;
        final stem = stemOf(file.path);
        final referenced = RegExp('(@(drawable|mipmap)/|R\\.(drawable|mipmap)\\.)$stem\\b').hasMatch(text);
        if (!referenced) offenders.add('${norm(file.path)} (${file.lengthSync()} B)');
      }
      expect(offenders, isEmpty, reason: 'referanssız büyük raster dosyalar APK\'ya girer: $offenders');
    });

    test('drawable* dizinlerinde aynı adlı ve baytları aynı kaynak yoktur (yinelenen launch_background.xml)', () {
      final byName = <String, List<File>>{};
      for (final file in filesUnder(res).where((f) => norm(f.path).contains('/drawable'))) {
        byName.putIfAbsent(norm(file.path).split('/').last, () => <File>[]).add(file);
      }
      for (final entry in byName.entries) {
        final files = entry.value;
        for (var i = 0; i < files.length; i++) {
          for (var j = i + 1; j < files.length; j++) {
            expect(sameBytes(files[i], files[j]), isFalse, reason: '${files[i].path} ile ${files[j].path} yinelenen kaynak');
          }
        }
      }
      expect(byName['launch_background.xml'], isNotNull);
    });

    test('referanssız splash_logo / splash_bg_circuit drawable\'ları kaldırılmıştır ve betikler bunları yeniden üretmez', () {
      for (final name in <String>['splash_logo', 'splash_bg_circuit']) {
        final leftovers = filesUnder(res).where((f) => stemOf(f.path) == name).toList();
        expect(leftovers, isEmpty, reason: '$name referanssız; yeniden eklenmemeli: ${leftovers.map((f) => f.path).toList()}');
      }
      for (final script in <String>['generate_adaptive_icons', 'generate_hd_splash', 'make_round_icons', 'restore_original_splash']) {
        // Yorum satırları atlanır: açıklama yorumları kaldırılan dosya adlarını anabilir.
        final code = read('scripts/$script.py').split(RegExp(r'\r?\n')).where((line) => !line.trimLeft().startsWith('#')).join('\n');
        expect(code, isNot(contains('splash_logo.png')), reason: 'scripts/$script.py');
        expect(code, isNot(contains('splash_bg_circuit.png')), reason: 'scripts/$script.py');
        expect(code.toLowerCase(), isNot(contains(r'g:\site\ev_otomasyon')), reason: 'scripts/$script.py: mutlak ana-ağaç yolu yok (betik kendi kopyasında çalışmalı)');
      }
      final splash = read('scripts/generate_hd_splash.py');
      expect(splash, contains('drawable-nodpi'));
      expect(splash, contains('splash_screen_full.webp'));
    });
  });
}
