import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/ui/pages/scheduled_rules_page.dart';
import 'package:ev_otomasyon/ui/widgets/rules/rule_logic.dart';
import 'package:ev_otomasyon/ui/widgets/settings/scheduled_rules_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Zamanlı kurallar: kanal listesi (evin gerçek uç noktaları, 1 tabanlı), çakışma uyarısı, yükleme
/// hatası ile boş liste ayrımı, yetki kapısı, saat dilimi ve kayıt sonrası yenileme doğrulaması.
void main() {
  ScheduledRule rule(
    String id, {
    int channel = 1,
    String type = 'relay',
    String action = 'off',
    int hour = 22,
    int minute = 0,
    List<int> days = const <int>[0, 1, 2, 3, 4, 5, 6],
    bool enabled = true,
    String? label,
    bool creatorActive = true,
  }) =>
      ScheduledRule(
        id: id,
        homeId: kHomeA,
        channel: channel,
        channelType: type,
        action: action,
        hour: hour,
        minute: minute,
        daysOfWeek: days,
        enabled: enabled,
        label: label,
        creatorActive: creatorActive,
      );

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('Kanal seçenekleri (evin gerçek uç noktalarından)', () {
    test('röle listesi panjur satırlarını içermez; her panjur çifti tek, 1 tabanlı panjur seçeneğidir', () {
      final options = ruleChannelOptions(testEndpoints());
      final relays = options.where((o) => o.type == 'relay').map((o) => o.channel).toList();
      final shutters = options.where((o) => o.type == 'shutter').toList();

      expect(relays, <int>[1, 2, 5, 6], reason: 'röle 3 ve 4 panjur çiftinin YUKARI/AŞAĞI röleleridir');
      expect(shutters, hasLength(1));
      expect(shutters.single.channel, 2, reason: 'panjur kanalı çift numarasıdır (1 tabanlı)');
      expect(shutters.single.label, 'Panjur 2 — Salon Panjur');
      expect(options.every((o) => o.channel >= 1), isTrue, reason: '0 tabanlı kanal yok');
    });

    test('eylemler kanala uygundur: panjur aç/kapat, darbe yalnızca tetikle, lamba aç/kapat', () {
      final endpoints = <EndpointModel>[
        ...testEndpoints(),
        const EndpointModel(
          id: 'e7',
          homeId: kHomeA,
          channel: 7,
          name: 'Kapı',
          room: 'Giriş',
          endpointType: 'impulse',
          currentState: false,
        ),
      ];
      final options = ruleChannelOptions(endpoints);
      expect(options.firstWhere((o) => o.id == 'shutter_2').actions, <String>['open', 'close']);
      expect(options.firstWhere((o) => o.id == 'relay_1').actions, <String>['on', 'off']);
      final gate = options.firstWhere((o) => o.id == 'relay_7');
      expect(gate.actions, <String>['on']);
      expect(gate.actionLabel('on'), 'Tetikle');
    });

    test('uygulama-ekranlar-5: güvenlik eylemcisi (vana/siren/fan) kanalları listelenmez; ilk seçenek geçerli kanal', () {
      EndpointModel ep(int ch, String name, {String? actuator}) => EndpointModel(
            id: 'e$ch',
            homeId: kHomeA,
            deviceId: 'dev-internal',
            deviceUuid: 'AHBU-S3-TEST01',
            channel: ch,
            name: name,
            room: 'Mutfak',
            endpointType: 'light',
            currentState: false,
            actuatorType: actuator,
          );
      final options = ruleChannelOptions(<EndpointModel>[
        ep(1, 'Su Vanası', actuator: 'valve'),
        ep(2, 'Mutfak Lambası'),
        ep(3, 'Siren', actuator: 'siren'),
        ep(4, 'Fan', actuator: 'fan'),
      ]);
      expect(options.map((o) => o.id), <String>['relay_2'], reason: 'sunucu eylemci kanalında kuralı 400 ile reddeder');
      expect(options.first.channel, 2, reason: 'diyaloğun varsayılan (ilk) seçeneği eylemci değil');
    });

    test('uç nokta yoksa seçenek listesi boştur (uydurma kanal üretilmez)', () {
      expect(ruleChannelOptions(const <EndpointModel>[]), isEmpty);
    });
  });

  group('Çakışma tespiti', () {
    final existing = <ScheduledRule>[
      rule('a', action: 'off', hour: 22),
      rule('b', channel: 2, action: 'on', hour: 22),
      rule('c', action: 'on', hour: 22, enabled: false),
      rule('d', action: 'off', hour: 22, days: const <int>[6]),
    ];

    test('aynı kanal/saat/eylem ve ortak gün: yinelenen kural', () {
      final conflicts = findRuleConflicts(
        existing,
        channelType: 'relay',
        channel: 1,
        action: 'off',
        hour: 22,
        minute: 0,
        daysOfWeek: const <int>[1, 2],
      );
      expect(conflicts.map((c) => c.rule.id), <String>['a']);
      expect(conflicts.single.kind, RuleConflictKind.duplicate);
    });

    test('aynı kanal ve saatte ters eylem: ters çakışma; devre dışı ve ortak günü olmayan kurallar sayılmaz', () {
      final conflicts = findRuleConflicts(
        existing,
        channelType: 'relay',
        channel: 1,
        action: 'on',
        hour: 22,
        minute: 0,
        daysOfWeek: const <int>[1],
      );
      expect(conflicts.map((c) => c.rule.id), <String>['a']);
      expect(conflicts.single.kind, RuleConflictKind.opposite);
    });

    test('farklı kanal veya farklı saat çakışmaz; düzenlenen kuralın kendisi dışlanır', () {
      expect(
        findRuleConflicts(existing, channelType: 'relay', channel: 3, action: 'off', hour: 22, minute: 0, daysOfWeek: const <int>[1]),
        isEmpty,
      );
      expect(
        findRuleConflicts(existing, channelType: 'relay', channel: 1, action: 'off', hour: 23, minute: 0, daysOfWeek: const <int>[1]),
        isEmpty,
      );
      expect(
        findRuleConflicts(existing, channelType: 'relay', channel: 1, action: 'off', hour: 22, minute: 0, daysOfWeek: const <int>[1], ignoreId: 'a'),
        isEmpty,
      );
    });

    test('ev saat dilimi okunur gösterilir', () {
      expect(homeTimezoneLabel('Europe/Istanbul'), 'Türkiye saati (Europe/Istanbul, UTC+3)');
      expect(homeTimezoneLabel(''), 'Türkiye saati (Europe/Istanbul, UTC+3)');
      expect(homeTimezoneLabel('Europe/Berlin'), 'Europe/Berlin');
    });
  });

  group('Zamanlı kurallar sayfası', () {
    testWidgets('yükleme HATASI "kural yok" değil "yüklenemedi" gösterir; yeniden deneyince liste gelir', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rulesError = kServerError,
      );
      await flush(tester);

      expect(find.text('Kurallar yüklenemedi'), findsOneWidget);
      expect(find.text(kServerError.message), findsOneWidget);
      expect(find.text('Henüz zamanlı kural yok'), findsNothing);

      h.e1
        ..rulesError = null
        ..rules = <ScheduledRule>[rule('r1', label: 'Gece Kapat')];
      await tester.tap(byKeyName('btn_retry'));
      await flush(tester);
      expect(find.text('Gece Kapat'), findsOneWidget);
      expect(find.text('Kurallar yüklenemedi'), findsNothing);
    });

    testWidgets('başarılı boş yanıt "Henüz zamanlı kural yok" gösterir ve ev sahibine ekleme yolu sunar', (tester) async {
      await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      expect(byKeyName('view_rules_empty'), findsOneWidget);
      expect(find.text('Henüz zamanlı kural yok'), findsOneWidget);
      expect(byKeyName('btn_add_first_rule'), findsOneWidget);
      expect(byKeyName('btn_add_rule'), findsOneWidget);
    });

    testWidgets('yükleme sürerken zaman aşımından sonra "Yeniden dene" çıkar (sonsuz spinner yok)', (tester) async {
      final gate = Completer<void>();
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rulesGate = gate,
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await flush(tester);
      expect(byKeyName('loading_view'), findsOneWidget);
      expect(byKeyName('btn_retry'), findsNothing);

      h.clock.advance(const Duration(seconds: 16));
      await flush(tester);
      expect(find.text('Bu işlem beklenenden uzun sürüyor.'), findsOneWidget);
      expect(byKeyName('btn_retry'), findsOneWidget);
    });

    testWidgets('evin saat dilimi gösterilir', (tester) async {
      await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      expect(
        find.textContaining('Türkiye saati (Europe/Istanbul, UTC+3)'),
        findsOneWidget,
      );
    });

    testWidgets('ev başka saat dilimindeyse o dilim yazılır', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        home: const HomeModel(id: kHomeA, name: 'Berlin Evi', role: 'owner', timezone: 'Europe/Berlin'),
      );
      await flush(tester);
      expect(find.textContaining('Europe/Berlin'), findsOneWidget);
    });

    test('kullanim-5: creator_active ayrıştırılır (alan yoksa true)', () {
      Map<String, dynamic> json({Object? creatorActive}) => <String, dynamic>{
            'id': 'r1',
            'home_id': kHomeA,
            'channel': 1,
            'channel_type': 'relay',
            'action': 'on',
            'hour': 7,
            'minute': 0,
            'days_of_week': <int>[1],
            'creator_active': ?creatorActive,
          };
      expect(ScheduledRule.fromJson(json()).creatorActive, isTrue, reason: 'eski sunucu');
      expect(ScheduledRule.fromJson(json(creatorActive: false)).creatorActive, isFalse);
      expect(ScheduledRule.fromJson(json(creatorActive: false)).copyWith(enabled: false).creatorActive, isFalse);
    });

    testWidgets('kullanim-5: kuranın erişimi bitmiş kuralda amber not; kapalı kurallar için ipucu', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[
          rule('r1', creatorActive: false),
          rule('r2', channel: 2, enabled: false),
        ],
      );
      await flush(tester);
      expect(find.byKey(const Key('note_rule_creator_r1')), findsOneWidget);
      expect(
        find.text('Çalışmıyor: kuralı kuranın erişimi bitti. Düzenleyip kaydederek kuralı üstlenin.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('note_rule_creator_r2')), findsNothing);
      expect(
        find.text('Kuralı oluşturan kişinin erişimi sona erdiyse kural çalışmaz; kaydederseniz sizin adınıza çalışır.'),
        findsOneWidget,
      );
    });

    testWidgets('kural kartı kanalı uç nokta adıyla gösterir (etiket yoksa)', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('r1', channel: 5), rule('r2', channel: 2, type: 'shutter', action: 'close', hour: 7)],
      );
      await flush(tester);
      expect(find.text('Mutfak'), findsOneWidget, reason: 'röle 5 = Mutfak');
      expect(find.text('Salon Panjur'), findsOneWidget, reason: 'panjur çifti 2');
      expect(find.text('Röle 5 • Kapat'), findsOneWidget);
      expect(find.text('Panjur 2 • Kapat'), findsOneWidget);
    });
  });

  group('Kural ekleme / düzenleme / silme', () {
    testWidgets('kanal listesi evin gerçek uç noktalarıdır (panjur röleleri "röle" olarak listelenmez)', (tester) async {
      await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      await tester.tap(byKeyName('btn_add_rule'));
      await flush(tester);
      await tester.tap(byKeyName('field_rule_channel'));
      await tester.pumpAndSettle();

      expect(find.text('Röle 1 — Avize'), findsWidgets);
      expect(find.text('Röle 5 — Mutfak'), findsWidgets);
      expect(find.text('Panjur 2 — Salon Panjur'), findsWidgets);
      expect(find.textContaining('Röle 3'), findsNothing);
      expect(find.textContaining('Röle 4'), findsNothing);
    });

    testWidgets('yeni kural 1 tabanlı kanal ve cihaz kimliğiyle sunucuya gönderilir; liste yenilenince başarı bildirilir',
        (tester) async {
      final h = await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      await tester.tap(byKeyName('btn_add_rule'));
      await flush(tester);
      await tester.tap(byKeyName('btn_save_rule'));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));

      final payload = h.e1.createdRulePayloads.single;
      expect(payload['channel'], 1, reason: '1 tabanlı');
      expect(payload['channel_type'], 'relay');
      expect(payload['action'], 'off');
      expect(payload['days_of_week'], <int>[0, 1, 2, 3, 4, 5, 6]);
      expect(payload['device_id'], 'dev-internal');
      expect(find.text('Kural eklendi'), findsOneWidget);
      expect(byKeyName('card_rule_rule-1'), findsOneWidget);
    });

    testWidgets('kayıt sonrası liste YENİLENEMEZSE başarı gösterilmez; uyarı ve "Yenile" çıkar', (tester) async {
      final h = await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      await tester.tap(byKeyName('btn_add_rule'));
      await flush(tester);

      // Kayıt gider, ama ardından gelen liste isteği başarısız olur.
      h.e1.rulesError = kNetworkError;
      await tester.tap(byKeyName('btn_save_rule'));
      await flush(tester);
      await tester.pump(const Duration(milliseconds: 400));

      expect(h.e1.createdRulePayloads, hasLength(1));
      expect(find.text('Kural eklendi'), findsNothing, reason: 'doğrulanmayan başarı iddia edilmez');
      expect(find.textContaining('liste yenilenemedi'), findsOneWidget);
      expect(find.text('Yenile'), findsOneWidget);
    });

    testWidgets('sunucu hatası diyalogda Türkçe mesajla kalır; girdi kaybolmaz', (tester) async {
      final h = await pumpReady(tester, const ScheduledRulesPage());
      await flush(tester);
      await tester.tap(byKeyName('btn_add_rule'));
      await flush(tester);
      await tester.enterText(byKeyName('field_rule_label'), 'Benim kuralım');

      h.e1.ruleWriteError = kServerError;
      await tester.tap(byKeyName('btn_save_rule'));
      await flush(tester);

      expect(find.text(kServerError.message), findsOneWidget);
      expect(byKeyName('dialog_rule'), findsOneWidget, reason: 'diyalog açık kalır');
      expect(find.text('Benim kuralım'), findsOneWidget, reason: 'girdi korunur');
      expect(tester.takeException(), isNull);
    });

    testWidgets('aynı kanal/saat için ters eylemli kural varsa çakışma uyarısı çıkar ve düğme "Yine de Kaydet" olur',
        (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[
          rule('a', action: 'off'),
          rule('b', action: 'on'),
        ],
      );
      await flush(tester);

      // 'a' (kapat) düzenlenirken aynı saatte 'b' (aç) ters çakışır.
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_edit_a'));
      await tester.pumpAndSettle();

      expect(byKeyName('banner_rule_conflict'), findsOneWidget);
      expect(find.textContaining('ters eylemli'), findsOneWidget);
      expect(find.text('Yine de Kaydet'), findsOneWidget);

      // Eylem 'Aç' yapılınca yinelenen kural uyarısı olur.
      await tester.tap(byKeyName('btn_rule_action_on'));
      await tester.pump();
      expect(find.textContaining('zaten var'), findsOneWidget);
    });

    testWidgets('çakışma yoksa uyarı gösterilmez', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a', action: 'off')],
      );
      await flush(tester);
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_edit_a'));
      await tester.pumpAndSettle();
      expect(byKeyName('banner_rule_conflict'), findsNothing);
      expect(find.text('Güncelle'), findsOneWidget);
    });

    testWidgets('anahtar kuralı sunucuda kapatır ve kart güncellenir', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a')],
      );
      await flush(tester);
      expect(tester.widget<Switch>(byKeyName('switch_rule_a')).value, isTrue);

      await tester.tap(byKeyName('switch_rule_a'));
      await flush(tester);
      expect(h.e1.rules.single.enabled, isFalse);
      expect(tester.widget<Switch>(byKeyName('switch_rule_a')).value, isFalse);
    });

    testWidgets('silme onay ister; onaylanınca kural kalkar', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a', label: 'Silinecek')],
      );
      await flush(tester);
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_delete_a'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_delete_rule'), findsOneWidget);
      expect(h.e1.calls, isNot(contains('deleteScheduledRule')), reason: 'onaydan önce silinmez');

      await tester.tap(byKeyName('btn_confirm_delete_rule'));
      await flush(tester);
      expect(h.e1.rules, isEmpty);
      expect(byKeyName('card_rule_a'), findsNothing);
      expect(find.text('Kural silindi'), findsOneWidget);
    });

    testWidgets('silme hatası ham istisna değil Türkçe mesajla gösterilir', (tester) async {
      final h = await pumpReady(
        tester,
        const ScheduledRulesPage(),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a')],
      );
      await flush(tester);
      h.e1.ruleWriteError = kServerError;
      await tester.tap(byKeyName('menu_rule_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_rule_delete_a'));
      await tester.pumpAndSettle();
      await tester.tap(byKeyName('btn_confirm_delete_rule'));
      await flush(tester);
      expect(find.text(kServerError.message), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(byKeyName('card_rule_a'), findsOneWidget, reason: 'silinemediyse kart durur');
    });
  });

  group('Yetki kapısı: canManageRules', () {
    for (final entry in <String, ({String role, String global, bool guest})>{
      'misafir': (role: 'guest', global: 'user', guest: true),
      'servis PIN oturumu': (role: 'service_session', global: 'service_session', guest: false),
    }.entries) {
      testWidgets('${entry.key}: ekleme/düzenleme yok, anahtarlar pasif (salt-okunur)', (tester) async {
        final v = entry.value;
        await pumpReady(
          tester,
          const ScheduledRulesPage(),
          role: v.role,
          globalRole: v.global,
          home: v.guest ? guestHome() : null,
          configure: (h) => h.e1.rules = <ScheduledRule>[rule('a')],
        );
        await flush(tester);
        expect(byKeyName('btn_add_rule'), findsNothing);
        expect(byKeyName('menu_rule_a'), findsNothing);
        expect(tester.widget<Switch>(byKeyName('switch_rule_a')).onChanged, isNull);
      });
    }

    testWidgets('aile üyesi kural yönetebilir (matris: resident ✔)', (tester) async {
      await pumpReady(
        tester,
        const ScheduledRulesPage(),
        role: 'resident',
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a')],
      );
      await flush(tester);
      expect(byKeyName('btn_add_rule'), findsOneWidget);
      expect(byKeyName('menu_rule_a'), findsOneWidget);
    });
  });

  group('Ayarlardaki kural özet kartı: sayı ayarlar açılırken yüklenir', () {
    testWidgets('yükleme sürerken "yükleniyor…" gösterir, yanlış "kural yok" demez', (tester) async {
      final gate = Completer<void>();
      await pumpReady(
        tester,
        scaffolded(const ScheduledRulesCard()),
        configure: (h) => h.e1.rulesGate = gate,
      );
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await flush(tester);
      expect(find.text('Kurallar yükleniyor…'), findsOneWidget);
      expect(find.text('Henüz kural tanımlanmamış'), findsNothing);
    });

    testWidgets('yükleme hatasında "yüklenemedi" der (kural yok demez)', (tester) async {
      await pumpReady(
        tester,
        scaffolded(const ScheduledRulesCard()),
        configure: (h) => h.e1.rulesError = kServerError,
      );
      await flush(tester);
      expect(find.textContaining('Kurallar yüklenemedi'), findsOneWidget);
      expect(find.text('Henüz kural tanımlanmamış'), findsNothing);
    });

    testWidgets('başarılı yanıtta sayıyı gösterir', (tester) async {
      await pumpReady(
        tester,
        scaffolded(const ScheduledRulesCard()),
        configure: (h) => h.e1.rules = <ScheduledRule>[rule('a'), rule('b', enabled: false), rule('c')],
      );
      await flush(tester);
      expect(find.text('2 aktif / 3 kural'), findsOneWidget);
    });

    testWidgets('başarılı boş yanıtta "Henüz kural tanımlanmamış" der', (tester) async {
      await pumpReady(tester, scaffolded(const ScheduledRulesCard()));
      await flush(tester);
      expect(find.text('Henüz kural tanımlanmamış'), findsOneWidget);
    });
  });
}
