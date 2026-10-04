import 'package:ev_otomasyon/ui/theme/feature_accent.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';

/// Özellik vurgu haritası (WP-V9 C): AYNI özellik her yerde aynı aile; aynı listedeki İKİ FARKLI özellik aynı aileyi paylaşmaz.
/// Bu test haritayı KİLİTLER: bir özelliğin rengini değiştirmek bilinçli bir karardır (tabloyu ve belgeyi birlikte güncelleyin).
void main() {
  group('harita tablosu (kilit)', () {
    // `docs/superpowers/analysis/gorsel-bilesen-api.md` "AppFeature vurgu haritası" tablosuyla AYNI.
    const expected = <AppFeature, String>{
      AppFeature.inventory: 'cyan',
      AppFeature.subscribers: 'sky',
      AppFeature.doctor: 'emerald',
      AppFeature.boardReplace: 'violet',
      AppFeature.emergencyReset: 'rose',
      AppFeature.wifiRecovery: 'amber',
      AppFeature.servicePin: 'amber',
      AppFeature.management: 'slate',
      AppFeature.commissioning: 'slate',
      AppFeature.family: 'sky',
      AppFeature.ownershipTransfer: 'amber',
      AppFeature.rules: 'cyan',
      AppFeature.nightPeace: 'violet',
      AppFeature.childLock: 'amber',
      AppFeature.biometric: 'emerald',
      AppFeature.deviceHost: 'sky',
      AppFeature.telemetry: 'cyan',
      AppFeature.appearance: 'sky',
      AppFeature.settings: 'cyan',
      AppFeature.superConsole: 'violet',
      AppFeature.serviceConsole: 'cyan',
    };

    test('her özellik tabloda ve tablodaki aileyi taşır (tabloda olmayan özellik yok)', () {
      expect(expected.keys.toSet(), AppFeature.values.toSet(), reason: 'yeni özellik eklenince tablo da güncellenmeli');
      for (final entry in expected.entries) {
        expect(featureFamily(entry.key).name, entry.value, reason: entry.key.name);
      }
    });

    test('servis ajanının yerel haritasıyla UYUMLU: envanter cyan, aboneler sky, doktor emerald, pano değişimi violet, acil sıfırlama rose, Wi-Fi amber', () {
      expect(AppFeature.inventory.accentFamily, AppFamilies.cyan);
      expect(AppFeature.subscribers.accentFamily, AppFamilies.sky);
      expect(AppFeature.doctor.accentFamily, AppFamilies.emerald);
      expect(AppFeature.boardReplace.accentFamily, AppFamilies.violet);
      expect(AppFeature.emergencyReset.accentFamily, AppFamilies.rose);
      expect(AppFeature.wifiRecovery.accentFamily, AppFamilies.amber);
    });

    test('featureFamily(f) == f.accentFamily ve her aile AppFamilies.all içindedir', () {
      for (final f in AppFeature.values) {
        expect(featureFamily(f), same(f.accentFamily));
        expect(AppFamilies.all, contains(f.accentFamily), reason: f.name);
      }
    });

    test('anlam (şartname §2.1): rose YALNIZ tehlike (acil sıfırlama); violet yalnız gece/ek modül/süper konsol; çocuk kilidi ve servis erişimi amber', () {
      expect(AppFeature.values.where((f) => f.accentFamily == AppFamilies.rose), <AppFeature>[AppFeature.emergencyReset],
          reason: 'rose yalnız tehlike: pano değişimi rose DEĞİL (eskiden servis panelinde rose idi)');
      expect(
        AppFeature.values.where((f) => f.accentFamily == AppFamilies.violet).toSet(),
        <AppFeature>{AppFeature.boardReplace, AppFeature.nightPeace, AppFeature.superConsole},
      );
      expect(AppFeature.servicePin.accentFamily, isNot(AppFamilies.violet), reason: 'servis PIN + pano değişimi artık aynı renk değil');
      expect(AppFeature.childLock.accentFamily, AppFamilies.amber);
      expect(AppFeature.wifiRecovery.accentFamily, AppFamilies.amber);
    });

    test('tüm renk aileleri kullanılır (kullanılmayan aile yok): harita paleti boşa harcamaz', () {
      final used = AppFeature.values.map((f) => f.accentFamily).toSet();
      expect(used, AppFamilies.all.toSet());
    });
  });

  group('benzersizlik: aynı listedeki iki farklı özellik AYNI aileyi paylaşmaz', () {
    for (final entry in FeatureGroups.all.entries) {
      test(entry.key, () {
        final features = entry.value;
        expect(features.toSet().length, features.length, reason: '${entry.key}: özellik listede bir kez yazılır');
        expect(features.length, greaterThanOrEqualTo(2));
        final byFamily = <String, List<String>>{};
        for (final f in features) {
          byFamily.putIfAbsent(f.accentFamily.name, () => <String>[]).add(f.name);
        }
        final clashes = byFamily.entries.where((e) => e.value.length > 1).toList();
        expect(clashes, isEmpty, reason: '${entry.key}: aynı aileyi paylaşan özellikler: $clashes');
      });
    }

    test('gruplar tanımlı ve beklenen listeler (çekmeceler, konsollar, araç kartları, ayarlar)', () {
      expect(
        FeatureGroups.all.keys,
        <String>[
          'superDrawer',
          'serviceDrawer',
          'superConsole',
          'serviceConsole',
          'servicePanelTools',
          'managementTools',
          'settingsDevice',
          'settingsAutomation',
        ],
      );
      // Servis araç kartları: 5 özellik, 5 ayrı aile (eskiden aboneler/hesaplar/sihirbaz ortak 'sky' idi).
      expect(FeatureGroups.servicePanelTools.map((f) => f.accentFamily.name).toSet().length, 5);
      expect(FeatureGroups.managementTools.map((f) => f.accentFamily.name).toSet().length, 5);
    });
  });
}
