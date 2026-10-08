import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/channels_page.dart';
import 'package:ev_otomasyon/ui/pages/device_settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// bireysel-10: kendi kuran ev sahibi kanal adını / odasını, lamba <-> priz tipini ve panjur süresini değiştirebilir
/// ("Kanallar ve Panjurlar"; `PUT /homes/:homeId/endpoints/:id`).
void main() {
  const tall = Size(800, 2600);

  group('ayarlar girişi', () {
    testWidgets('ev sahibinde "Kanallar ve Panjurlar" girişi var', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), role: 'owner', size: tall);
      expect(byKeyName('card_channels'), findsOneWidget);
      await tester.ensureVisible(byKeyName('btn_open_channels'));
      await tester.tap(byKeyName('btn_open_channels'));
      await tester.pumpAndSettle();
      expect(find.byType(ChannelsPage), findsOneWidget);
    });

    testWidgets('misafirde ve sakinde giriş yok', (tester) async {
      await pumpReady(tester, const DeviceSettingsPage(), home: guestHome(), size: tall);
      expect(byKeyName('card_channels'), findsNothing);
    });
  });

  group('düzenleme', () {
    Future<StateHarness> openEdit(WidgetTester tester, String endpointId, {bool deviceOnline = true}) async {
      final h = await pumpReady(tester, const ChannelsPage(), role: 'owner', size: tall, deviceOnline: deviceOnline);
      await tester.pumpAndSettle();
      expect(byKeyName('channels_sync_note'), findsOneWidget);
      await tester.ensureVisible(byKeyName('btn_edit_channel_$endpointId'));
      await tester.tap(byKeyName('btn_edit_channel_$endpointId'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('lamba: ad ve tip (priz) kaydedilir; yalnız değişen alanlar gider', (tester) async {
      final h = await openEdit(tester, 'e1');
      await tester.enterText(byKeyName('field_channel_name'), 'Tavan Lambası');
      await tester.tap(byKeyName('chip_type_plug'));
      await tester.pump();
      await tester.tap(byKeyName('btn_channel_save'));
      await tester.pumpAndSettle();

      final args = (h.cloud as E1Cloud).endpointUpdateArgs.single;
      expect(args['endpointId'], 'e1');
      expect(args['name'], 'Tavan Lambası');
      expect(args['type'], 'plug');
      expect(args['room'], isNull);
      expect(args['shutterDurationSec'], isNull);
      expect(byKeyName('channel_edit_dialog'), findsNothing, reason: 'başarıda kapanır');
    });

    testWidgets('boş ad kaydedilmez', (tester) async {
      final h = await openEdit(tester, 'e1');
      await tester.enterText(byKeyName('field_channel_name'), '   ');
      await tester.tap(byKeyName('btn_channel_save'));
      await tester.pumpAndSettle();
      expect((h.cloud as E1Cloud).endpointUpdateArgs, isEmpty);
      expect(byKeyName('channel_edit_dialog'), findsOneWidget);
    });

    testWidgets('panjur süresi kaydedilir; 409 NOT_APPLIED ayrı mesajla gösterilir', (tester) async {
      final h = await openEdit(tester, 'e3');
      final cloud = h.cloud as E1Cloud;
      cloud.endpointUpdateError = const ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Pano panjur süresini uygulamadı.',
        details: <String, dynamic>{'code': 'CONFLICT', 'reason': 'NOT_APPLIED'},
      );
      await tester.enterText(byKeyName('field_channel_duration'), '25');
      await tester.tap(byKeyName('btn_channel_save'));
      await tester.pumpAndSettle();

      expect(cloud.endpointUpdateArgs.single['shutterDurationSec'], 25);
      expect(find.text('Panjur hareket halinde; durdurup yeniden deneyin.'), findsOneWidget);
      expect(byKeyName('channel_edit_dialog'), findsOneWidget);
    });

    testWidgets('409 TYPE_CHANGED: liste yenilenir ve pencere kapanır', (tester) async {
      final h = await openEdit(tester, 'e1');
      final cloud = h.cloud as E1Cloud;
      cloud.endpointUpdateError = const ApiException(
        statusCode: 409,
        code: 'CONFLICT',
        message: 'Kanal tipi değişti; listeyi yenileyin.',
        details: <String, dynamic>{'code': 'CONFLICT', 'reason': 'TYPE_CHANGED'},
      );
      final before = cloud.count('fetchEndpoints');
      await tester.tap(byKeyName('chip_type_plug'));
      await tester.pump();
      await tester.tap(byKeyName('btn_channel_save'));
      await tester.pumpAndSettle();
      expect(cloud.count('fetchEndpoints'), greaterThan(before));
      expect(byKeyName('channel_edit_dialog'), findsNothing);
    });

    testWidgets('pano çevrimdışıyken süre alanı pasif ve açıklamalı', (tester) async {
      await openEdit(tester, 'e3', deviceOnline: false);
      final field = tester.widget<TextField>(byKeyName('field_channel_duration'));
      expect(field.enabled, isFalse);
      expect(find.textContaining('Pano çevrimdışı'), findsWidgets);
    });
  });
}
