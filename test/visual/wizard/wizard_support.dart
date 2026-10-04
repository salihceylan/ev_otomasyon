import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Sihirbaz galerisi için ek yazı tipi: uygulama `fontFamily: 'monospace'` ister (cihazda platform sabit aralıklı
/// yazı tipi); testte tanımsız olduğundan kutucuk çizerdi. Roboto'ya bağlanır (yalnız görsel galeri; uygulama koduna
/// dokunulmaz).
bool _monospaceLoaded = false;

Future<void> loadMonospaceAlias() async {
  if (_monospaceLoaded) return;
  var dir = File(Platform.resolvedExecutable).parent;
  String? root;
  final env = Platform.environment['FLUTTER_ROOT'];
  if (env != null && Directory('$env/bin/cache/artifacts/material_fonts').existsSync()) root = env;
  for (var i = 0; root == null && i < 10; i++) {
    if (Directory('${dir.path}/bin/cache/artifacts/material_fonts').existsSync()) root = dir.path;
    dir = dir.parent;
  }
  if (root == null) throw StateError('Flutter SDK yazı tipleri bulunamadı');
  final bytes = await File('$root/bin/cache/artifacts/material_fonts/roboto-regular.ttf').readAsBytes();
  final loader = FontLoader('monospace')..addFont(Future<ByteData>.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
  await loader.load();
  _monospaceLoaded = true;
}

/// Sihirbaz galerisinde tüm yazı tipi kurulumunu yapar (`setUpAll` içinde çağrılır).
Future<void> loadWizardGalleryExtras() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  await loadMonospaceAlias();
}
