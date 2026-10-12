import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:ev_otomasyon/ui/widgets/settings/info_cards.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Müşteri tarafı (servis sorumlusu kapsamı, migration 045): ev sahibi / sakin ayarlarında evin servisi SALT OKUNUR
/// "Servisiniz: ad · telefon" kartı. Servis yoksa (kök kapsamı / eski sunucu) kart hiç çizilmez; müşteri servisi kaldıramaz.
void main() {
  const tall = Size(800, 4200);

  const service = HomeServiceInfo(name: 'Ahmet Servis', phone: '0555 111 22 33');

  HomeModel homeWith({String role = 'owner', HomeServiceInfo? svc = service}) =>
      HomeModel(id: kHomeA, name: 'Ev A', role: role, mqttTopicId: 'h_test', service: svc);

  group('Servisiniz kartı (ayarlar)', () {
    testWidgets('ev sahibi: "Servisiniz: Ahmet Servis · 0555 111 22 33" ve salt-okunur açıklama görünür', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', home: homeWith(), size: tall);

      expect(byKeyName('card_home_service'), findsOneWidget);
      expect(find.text('Servisiniz: Ahmet Servis · 0555 111 22 33'), findsOneWidget);
      expect(find.text('Bu bilgi salt okunurdur; servis değişikliğini yalnızca yönetici yapabilir.'), findsOneWidget);
      expect(byKeyName('btn_copy_service_phone'), findsOneWidget);
    });

    testWidgets('aile üyesi (sakin) de görür', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'resident', home: homeWith(role: 'resident'), size: tall);
      expect(find.text('Servisiniz: Ahmet Servis · 0555 111 22 33'), findsOneWidget);
    });

    testWidgets('servis yoksa (kök kapsamı ya da eski sunucu) kart ve boşluk çizilmez', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', home: homeWith(svc: null), size: tall);

      expect(byKeyName('card_home_service'), findsNothing);
      expect(find.textContaining('Servisiniz'), findsNothing);
      expect(byKeyName('card_hardware_notice'), findsOneWidget, reason: 'diğer kartlar yerinde');
    });

    testWidgets('telefon yoksa yalnız ad yazılır ve kopyala düğmesi çıkmaz', (tester) async {
      await pumpReady(
        tester,
        const DeviceSettingsPage(),
        role: 'owner',
        home: homeWith(svc: const HomeServiceInfo(name: 'Ahmet Servis')),
        size: tall,
      );
      expect(find.text('Servisiniz: Ahmet Servis'), findsOneWidget);
      expect(byKeyName('btn_copy_service_phone'), findsNothing);
    });

    testWidgets('misafir görmez (ev sahibi / sakin ekranı); düzenleme/kaldırma düğmesi hiçbir rolde yok', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), home: guestHome(), size: tall);
      expect(byKeyName('card_home_service'), findsNothing);

      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', home: homeWith(), size: tall);
      expect(find.byType(HomeServiceCard), findsOneWidget);
      for (final label in <String>['Kaldır', 'Servisi Kaldır', 'Servisi Değiştir', 'Düzenle']) {
        expect(find.text(label), findsNothing, reason: 'müşteri servisi kaldıramaz/değiştiremez: $label');
      }
    });

    testWidgets('telefon düğmesi numarayı panoya kopyalar ve bilgi verir', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', home: homeWith(), size: tall);
      await tester.ensureVisible(byKeyName('btn_copy_service_phone'));
      await tester.tap(byKeyName('btn_copy_service_phone'));
      await tester.pump();

      expect(copied, '0555 111 22 33');
      expect(find.text('Servis telefonu panoya kopyalandı.'), findsOneWidget);
    });

    for (final scale in <double>[1.0, 1.5, 2.0]) {
      testWidgets('dar ekran (360 dp) ve yazı ölçeği $scale: uzun servis adı kesilmeden/taşmadan sarılır', (tester) async {
        await pumpReady(
          tester,
          const DeviceSettingsPage(),
          role: 'owner',
          home: homeWith(svc: const HomeServiceInfo(name: 'Ahmet Servis Elektronik Sistemleri Anonim Şirketi', phone: '0555 111 22 33')),
          size: const Size(360, 4800),
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        expect(byKeyName('card_home_service'), findsOneWidget);
        expect(find.textContaining('Ahmet Servis Elektronik'), findsOneWidget);
      });
    }

    test('satır biçimi: telefon varsa "ad · telefon"', () {
      expect(HomeServiceCard.lineOf(service), 'Servisiniz: Ahmet Servis · 0555 111 22 33');
      expect(HomeServiceCard.lineOf(const HomeServiceInfo(name: 'Ahmet Servis')), 'Servisiniz: Ahmet Servis');
    });
  });
}
