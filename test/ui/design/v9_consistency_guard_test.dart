import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// WP-V9 tutarlılık bekçisi (kaynak taraması): ortak bileşenlerin yerini ELLE yazılmış varyantlar yeniden almasın.
/// Çapraz eleştirmen bulgularının (#5 düğme plakası, #6 özellik rengi, #12 üst çubuk, #14 rozet/çip, #29 12 sp) regresyon kilidi.
void main() {
  final root = Directory('lib/ui');

  List<File> dartFiles() => root.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).toList();

  String read(String path) => File(path).readAsStringSync();

  /// Yorum satırlarını çıkarır (`//`, `///`): bekçi yalnız KOD satırlarına bakar.
  String code(String source) => source.split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');

  group('özellik haritası', () {
    test("yerel 'ServiceAccents' haritası kalmadı (AppFeature tek harita)", () {
      final offenders = [for (final f in dartFiles()) if (code(f.readAsStringSync()).contains('ServiceAccents')) f.path];
      expect(offenders, isEmpty, reason: 'AppFeature.<özellik>.accentFamily kullanın');
    });
  });

  group('NeonAppBar', () {
    const pages = <String>[
      'lib/ui/pages/device_inventory_page.dart',
      'lib/ui/pages/scheduled_rules_page.dart',
      'lib/ui/pages/service_management_page.dart',
      'lib/ui/pages/service_subscribers_page.dart',
      'lib/ui/pages/family/family_members_page.dart',
      'lib/ui/pages/device_settings_page.dart',
      'lib/ui/pages/service_mode_page.dart',
    ];

    for (final page in pages) {
      test('${page.split('/').last}: düz Material AppBar( yok, NeonAppBar( var', () {
        final source = code(read(page));
        expect(RegExp(r'(?<![A-Za-z])AppBar\(').hasMatch(source), isFalse, reason: 'düz AppBar yerine NeonAppBar');
        expect(source.contains('NeonAppBar('), isTrue);
      });
    }

    test("'ServiceAppBarTitle' (eski servis başlığı) kalmadı", () {
      final offenders = [for (final f in dartFiles()) if (code(f.readAsStringSync()).contains('ServiceAppBarTitle')) f.path];
      expect(offenders, isEmpty);
    });
  });

  group('rozet / çip', () {
    test("filtre ve seçim çipleri AppChip: bu dosyalarda ChoiceChip( kalmadı", () {
      const files = <String>[
        'lib/ui/pages/device_inventory_page.dart',
        'lib/ui/pages/service_management_page.dart',
        'lib/ui/dashboard/endpoint_sections.dart',
        'lib/ui/pages/service_setup/panel/admin_account_dialogs.dart',
        'lib/ui/pages/family/invite_family_dialog.dart',
      ];
      for (final f in files) {
        expect(code(read(f)).contains('ChoiceChip('), isFalse, reason: f);
        expect(code(read(f)).contains('AppChip('), isTrue, reason: f);
      }
    });

    test("eski elle yazılmış oda çipi (_GlassChip) kalmadı", () {
      expect(code(read('lib/ui/dashboard/endpoint_sections.dart')).contains('_GlassChip'), isFalse);
    });

    test('rozet sarmalayıcıları AppPill/AppPillShell çizer (GlassPill, StatusBadge, ModuleBadge, ServiceStatusPill, ServicePillShell, StatusPill)', () {
      expect(code(read('lib/ui/widgets/glass_pill.dart')), contains('AppPill.tinted('));
      expect(code(read('lib/ui/widgets/settings/status_badge.dart')), contains('AppPill('));
      expect(code(read('lib/ui/dashboard/module_badge.dart')), contains('AppPill('));
      expect(code(read('lib/ui/pages/service_setup/panel/service_glass.dart')), allOf(contains('AppPill.tinted('), contains('AppPillShell(')));
      expect(code(read('lib/ui/dashboard/status_pills.dart')), contains('AppPillShell('));
    });
  });

  group('düğme ve yazı tabanı', () {
    test("ElevatedButton.styleFrom içinde backgroundColor/shape/textStyle YOK (#5: alta plaka bırakır; accentButtonStyle/toneButtonStyle kullanın)", () {
      final offenders = <String>[];
      for (final f in dartFiles()) {
        if (f.path.endsWith('tone_button_surface.dart') || f.path.endsWith('accent_button.dart')) continue; // yardımcıların kendisi
        final source = code(f.readAsStringSync());
        var index = 0;
        while (true) {
          index = source.indexOf('ElevatedButton.styleFrom(', index);
          if (index < 0) break;
          var depth = 0;
          var end = index + 'ElevatedButton.styleFrom'.length;
          do {
            final ch = source[end];
            if (ch == '(') depth++;
            if (ch == ')') depth--;
            end++;
          } while (depth > 0 && end < source.length);
          final args = source.substring(index, end);
          if (RegExp(r'\b(backgroundColor|shape|textStyle)\s*:').hasMatch(args)) offenders.add(f.path);
          index = end;
        }
      }
      expect(offenders, isEmpty);
    });

    test('hiçbir kod satırında 12 sp altı sabit yazı boyutu yok (şartname §2.3: rozet/çip/etiket tabanı AppText.badge)', () {
      final offenders = <String>[];
      for (final f in dartFiles()) {
        final lines = code(f.readAsStringSync()).split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final m in RegExp(r'fontSize:\s*(\d+(?:\.\d+)?)').allMatches(lines[i])) {
            if (double.parse(m.group(1)!) < 12) offenders.add('${f.path}:${i + 1}');
          }
        }
      }
      expect(offenders, isEmpty);
    });
  });
}
