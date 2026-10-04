import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/api_exception.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Sunucu inceleme düzeltmesi (WP-L, CONTRACTS §2.4b): kapalı bir zamanlı kural yeniden açılırken sunucu kanal
/// tipini doğrular; uyumsuzsa `400 VALIDATION` + açıklayıcı Türkçe mesaj döner. Arayüz:
///
/// * mesajı AYNEN gösterir (genel "Kural güncellenemedi" metni değil),
/// * anahtar AÇILMAZ (görünen değer sunucudaki `enabled=false` ile aynı kalır) ve yeniden denenebilir,
/// * kural diyaloğunda (kaydet) mesaj alanın altında kalır, girdi kaybolmaz.
///
/// Sunucu sahtesi: `E1Cloud.ruleWriteError` (gerçek sunucu gövdesi `{success:false, message, code}` istemci yığınında
/// `ApiException`'a çevrilir; bu çevirinin kendisi `test/services/server_error_codes_test.dart`'ta sınanır).
void main() {
  /// Sunucunun gerçek mesajı (`scheduled_rules_service.js` `checkChannelAgainstEndpoints`): kanal 3-4 testEndpoints'te
  /// panjur çiftidir.
  const ApiException shutterChannelError = ApiException(
    statusCode: 400,
    code: 'VALIDATION',
    message: 'Kanal 3 bir panjura ayrılmış; röle kuralı yerine panjur kuralı oluşturun',
  );
  const genericFallback = 'Kural güncellenemedi. Lütfen tekrar deneyin.';

  /// Panjura dönmüş (3. kanal) bir kanaldaki röle kuralı; yerleşim eşitlemesi onu `enabled=false` yapmıştır.
  ScheduledRule closedByLayoutSync({String id = 'a'}) => ScheduledRule(
        id: id,
        homeId: kHomeA,
        channel: 3,
        channelType: 'relay',
        action: 'off',
        hour: 22,
        minute: 0,
        daysOfWeek: const <int>[0, 1, 2, 3, 4, 5, 6],
        enabled: false,
        label: 'Gece Kapat',
      );

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  bool switchValue(WidgetTester tester, String id) => tester.widget<Switch>(byKeyName('switch_rule_$id')).value;

  group('Kapalı kuralı yeniden açma: sunucu 400 VALIDATION', () {
    testWidgets('sunucunun mesajı gösterilir (genel metin değil) ve anahtar kapalı kalır', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);
      expect(switchValue(tester, 'a'), isFalse, reason: 'başlangıç: eşitlemenin kapattığı kural kapalı görünür');

      h.e1.ruleWriteError = shutterChannelError;
      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      expect(h.e1.calls.where((c) => c == 'updateScheduledRule'), hasLength(1), reason: 'istek sunucuya gitti');
      expect(find.text(shutterChannelError.message), findsOneWidget, reason: 'kullanıcıya sunucunun açıklaması gösterilir');
      expect(byKeyName('snack_friendly_error'), findsOneWidget);
      expect(find.text(genericFallback), findsNothing, reason: 'genel metin sunucunun mesajını gölgelemez');
      expect(switchValue(tester, 'a'), isFalse, reason: 'anahtar GERİ ALINDI: görünen değer sunucudaki enabled=false');
      expect(h.state.scheduledRules.single.enabled, isFalse, reason: 'durumdaki kural da değişmedi');
      expect(h.e1.rules.single.enabled, isFalse, reason: 'sunucudaki kural değişmedi');
      expect(tester.takeException(), isNull);
    });

    testWidgets('anahtarın anlamsal durumu da kapalı kalır (ekran okuyucu "açık" demez)', (tester) async {
      final semantics = tester.ensureSemantics();
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);
      h.e1.ruleWriteError = shutterChannelError;

      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      final node = tester.getSemantics(find.descendant(of: byKeyName('card_rule_a'), matching: find.byType(Switch)));
      expect(node.flagsCollection.isToggled.toBoolOrNull(), isFalse, reason: 'ekran okuyucu "kapalı" der');
      semantics.dispose();
    });

    testWidgets('hata kalkınca aynı anahtar yeniden denenir ve kural açılır (başarı yolu)', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);
      h.e1.ruleWriteError = shutterChannelError;
      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);
      expect(switchValue(tester, 'a'), isFalse);

      // Sunucu durumunun düzeldiği varsayılır (ör. pano yeniden röle olarak ayarlandı): aynı anahtar yeniden denenir.
      h.e1.ruleWriteError = null;
      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      expect(h.e1.rules.single.enabled, isTrue, reason: 'sunucu kuralı açtı');
      expect(switchValue(tester, 'a'), isTrue, reason: 'liste yenilendi ve anahtar açıldı');
      expect(h.e1.calls.where((c) => c == 'updateScheduledRule'), hasLength(2));
    });

    testWidgets('kural açma başarılıysa hata gösterilmez ve anahtar açılır', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);

      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      expect(h.e1.rules.single.enabled, isTrue);
      expect(switchValue(tester, 'a'), isTrue);
      expect(byKeyName('snack_friendly_error'), findsNothing);
      // Yalnızca anahtar gönderilir: kuralın öteki alanları (saat, etiket) olduğu gibi kalır.
      expect(h.e1.rules.single.hour, 22);
      expect(h.e1.rules.single.label, 'Gece Kapat');
    });

    testWidgets('diğer kuralların anahtarı etkilenmez; yalnızca reddedilen kural kapalı kalır', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[
          closedByLayoutSync(id: 'a'),
          ScheduledRule(
            id: 'b',
            homeId: kHomeA,
            channel: 5,
            channelType: 'relay',
            action: 'off',
            hour: 23,
            minute: 30,
            daysOfWeek: const <int>[0, 1, 2, 3, 4, 5, 6],
            enabled: true,
          ),
        ],
      );
      await flush(tester);
      h.e1.ruleWriteError = shutterChannelError;

      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      expect(switchValue(tester, 'a'), isFalse);
      expect(switchValue(tester, 'b'), isTrue, reason: 'başka kural açık kalır');
    });

    testWidgets('ApiException OLMAYAN beklenmeyen hatada (yalnızca) genel metin gösterilir', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);
      h.e1.ruleWriteError = StateError('beklenmeyen');

      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);

      expect(find.text(genericFallback), findsOneWidget);
      expect(find.textContaining('beklenmeyen'), findsNothing, reason: 'ham istisna metni sızmaz');
      expect(switchValue(tester, 'a'), isFalse);
    });
  });

  group('Kural diyaloğu (kaydet): sunucu 400 VALIDATION', () {
    testWidgets('düzenleme: mesaj alanın altında kalır, diyalog açık kalır, girdi korunur, kaydet yeniden etkindir',
        (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[closedByLayoutSync()],
      );
      await flush(tester);
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_edit_a'));
      await tester.pumpAndSettle();
      await tester.enterText(byKeyName('field_rule_label'), 'Yeni etiket');

      h.e1.ruleWriteError = shutterChannelError;
      await tester.tap(byKeyName('btn_save_rule'));
      await flush(tester);

      expect(byKeyName('dialog_rule'), findsOneWidget, reason: 'diyalog açık kalır');
      expect(find.descendant(of: byKeyName('dialog_rule'), matching: find.text(shutterChannelError.message)), findsOneWidget);
      expect(tester.widget<Text>(byKeyName('text_rule_error')).data, shutterChannelError.message);
      expect(find.text('Yeni etiket'), findsOneWidget, reason: 'girdi kaybolmaz');
      expect(find.text(genericFallback), findsNothing);
      final save = tester.widget<FilledButton>(byKeyName('btn_save_rule'));
      expect(save.onPressed, isNotNull, reason: 'kaydet yeniden denenebilir (takılı "kaydediliyor" yok)');
      expect(h.e1.rules.single.label, 'Gece Kapat', reason: 'sunucudaki kural değişmedi');
    });

    testWidgets('yeni kural: panjura ayrılmış kanal için sunucu mesajı diyalogda gösterilir', (tester) async {
      final h = await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      await tester.tap(byKeyName('btn_add_rule'));
      await flush(tester);

      h.e1.ruleWriteError = shutterChannelError;
      await tester.tap(byKeyName('btn_save_rule'));
      await flush(tester);

      expect(byKeyName('dialog_rule'), findsOneWidget);
      expect(tester.widget<Text>(byKeyName('text_rule_error')).data, shutterChannelError.message);
      expect(h.e1.createdRulePayloads, isEmpty, reason: 'kural oluşmadı');
    });
  });
}
