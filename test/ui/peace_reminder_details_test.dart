import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/peace_reminder_details.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'peace_ui_rig.dart';

/// `PeaceReminderDetails`: ayar kartına tek satırla konan son hatırlatma / cihaz özeti.

const _root = Key('peace_reminder_details');
const _last = Key('text_peace_last_notice');
const _devices = Key('text_peace_devices');
const _stale = Key('text_peace_stale');

/// Sabit "şimdi": 12 Mart 2026 09:00 (yerel).
final DateTime _now = DateTime(2026, 3, 12, 9, 0);

/// Yerel [DateTime] -> sunucunun UTC ISO metni (saat dilimine bağlı kalmasın).
String _iso(DateTime local) => local.toUtc().toIso8601String();

Map<String, dynamic> _v2({
  DateTime? created,
  String status = 'sent',
  DateTime? resolvedAt,
  int? lights = 2,
  int? shutters = 1,
  int? online = 1,
  int? total = 2,
  bool? stale = false,
  bool withLast = true,
}) => <String, dynamic>{
  'home_id': kHomeA,
  'enabled': true,
  'time': '23:30',
  'stale': ?stale,
  'devices_online': ?online,
  'devices_total': ?total,
  'open_lights_count': 0,
  'open_shutters_count': 0,
  if (withLast)
    'last_notice': <String, dynamic>{
      'id': 41,
      'status': status,
      'created_at': _iso(created ?? DateTime(2026, 3, 11, 23, 30)),
      'resolved_at': resolvedAt == null ? null : _iso(resolvedAt),
      'open_lights_count': ?lights,
      'open_shutters_count': ?shutters,
    },
};

/// Sunucu yanıtını gerçek `AutomationState.fetchPeaceNotification` yoluyla durumdan okutur.
Future<PeaceUiRig> _pump(
  WidgetTester tester,
  Map<String, dynamic>? data, {
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  double width = 320,
}) async {
  usePhone(tester, size: Size(width, 700));
  final rig = PeaceUiRig.create();
  addTearDown(rig.dispose);
  if (data != null) rig.cloud.peaceNotification = data;

  await tester.pumpWidget(
    ChangeNotifierProvider<AutomationState>.value(
      value: rig.state,
      child: MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [PeaceReminderDetails(now: () => _now)],
          ),
        ),
      ),
    ),
  );
  if (data != null) {
    await rig.state.fetchPeaceNotification();
    await tester.pump();
  }
  return rig;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('biçimleme (saf)', () {
    test('Bugün / Dün / tarih / başka yıl', () {
      expect(
        PeaceReminderDetails.formatMoment(DateTime(2026, 3, 12, 0, 5), _now),
        'Bugün 00:05',
      );
      expect(
        PeaceReminderDetails.formatMoment(DateTime(2026, 3, 11, 23, 30), _now),
        'Dün 23:30',
      );
      expect(
        PeaceReminderDetails.formatMoment(DateTime(2026, 3, 5, 7, 4), _now),
        '05.03 07:04',
      );
      expect(
        PeaceReminderDetails.formatMoment(DateTime(2025, 12, 31, 23, 59), _now),
        '31.12.2025 23:59',
      );
    });

    test('Dün, ay başında da doğru (1 Mart - 28 Şubat)', () {
      final first = DateTime(2026, 3, 1, 10, 0);
      expect(
        PeaceReminderDetails.formatMoment(DateTime(2026, 2, 28, 23, 0), first),
        'Dün 23:00',
      );
    });

    test('UTC an yerel saate çevrilir', () {
      final local = DateTime(2026, 3, 11, 23, 30);
      expect(
        PeaceReminderDetails.formatMoment(local.toUtc(), _now),
        'Dün 23:30',
      );
    });

    test('lastNoticeText: sayılar/zaman eksikse bozulmadan kısalır', () {
      final base = PeaceLastNotice(
        id: 1,
        createdAt: DateTime(2026, 3, 11, 23, 30),
      );
      expect(
        PeaceReminderDetails.lastNoticeText(base, _now),
        'Son hatırlatma: Dün 23:30 (kapatılmadı)',
      );
      expect(PeaceReminderDetails.lastNoticeText(null, _now), isNull);
      expect(
        PeaceReminderDetails.lastNoticeText(const PeaceLastNotice(id: 1), _now),
        isNull,
      );
      final onlyCounts = PeaceLastNotice(
        id: 1,
        openLightsCount: 3,
        resolvedAt: DateTime(2026, 3, 12, 0, 1),
      );
      expect(
        PeaceReminderDetails.lastNoticeText(onlyCounts, _now),
        'Son hatırlatma: açık 3 lamba (kapatıldı)',
      );
    });
  });

  group('görünüm', () {
    testWidgets(
      'v2 verisi: son hatırlatma (kapatılmadı), cihazlar ve uyarı yok',
      (tester) async {
        await _pump(tester, _v2());

        expect(find.byKey(_root), findsOneWidget);
        expect(
          find.text(
            'Son hatırlatma: Dün 23:30 - açık 2 lamba, 1 panjur (kapatılmadı)',
          ),
          findsOneWidget,
        );
        expect(find.text('Cihazlar: 1/2 çevrimiçi'), findsOneWidget);
        expect(find.byKey(_stale), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('çözülmüş kayıt (resolved_at): "(kapatıldı)"', (tester) async {
      await _pump(
        tester,
        _v2(status: 'resolved', resolvedAt: DateTime(2026, 3, 12, 0, 10)),
      );
      expect(
        find.text(
          'Son hatırlatma: Dün 23:30 - açık 2 lamba, 1 panjur (kapatıldı)',
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'yalnızca durum "resolved" (resolved_at yok) da kapatıldı sayılır',
      (tester) async {
        await _pump(tester, _v2(status: 'resolved'));
        expect(find.textContaining('(kapatıldı)'), findsOneWidget);
      },
    );

    testWidgets('bugün gelen kayıt "Bugün" ile gösterilir', (tester) async {
      await _pump(tester, _v2(created: DateTime(2026, 3, 12, 0, 5)));
      expect(
        find.textContaining('Son hatırlatma: Bugün 00:05 - '),
        findsOneWidget,
      );
    });

    testWidgets('stale: uyarı metni (simge + metin) ve cihaz satırı birlikte', (
      tester,
    ) async {
      await _pump(tester, _v2(stale: true, online: 0, total: 2));

      expect(
        find.text('Cihaz çevrimdışı; açık lamba bilgisi güncel değil.'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
      expect(find.text('Cihazlar: 0/2 çevrimiçi'), findsOneWidget);
      expect(find.byKey(_last), findsOneWidget);
    });

    testWidgets('yalnızca stale: tek uyarı satırı', (tester) async {
      await _pump(
        tester,
        _v2(stale: true, withLast: false, online: null, total: null),
      );
      expect(find.byKey(_stale), findsOneWidget);
      expect(find.byKey(_last), findsNothing);
      expect(find.byKey(_devices), findsNothing);
    });

    testWidgets('son hatırlatma yoksa yalnızca cihaz satırı', (tester) async {
      await _pump(tester, _v2(withLast: false));
      expect(find.byKey(_last), findsNothing);
      expect(find.text('Cihazlar: 1/2 çevrimiçi'), findsOneWidget);
    });

    testWidgets('v1 sunucu (v2 alanı yok): hiçbir şey çizilmez', (
      tester,
    ) async {
      await _pump(tester, <String, dynamic>{
        'home_id': kHomeA,
        'peace_notification_enabled': true,
        'peace_notification_time': '23:30',
        'open_lights_count': 2,
        'open_shutters_count': 0,
        'summary_text': 'Salonda 2 lamba açık.',
      });
      expect(find.byKey(_root), findsNothing);
    });

    testWidgets('veri hiç yoksa (henüz alınmadı) gizli', (tester) async {
      final rig = await _pump(tester, null);
      expect(rig.state.peaceNotificationData, isNull);
      expect(find.byKey(_root), findsNothing);
    });

    testWidgets(
      'bozuk last_notice (kimliksiz) ekranı düşürmez; cihaz satırı yine görünür',
      (tester) async {
        final data = _v2()
          ..['last_notice'] = <String, dynamic>{'status': 'sent'};
        await _pump(tester, data);
        expect(tester.takeException(), isNull);
        expect(find.byKey(_last), findsNothing);
        expect(find.byKey(_devices), findsOneWidget);
      },
    );

    testWidgets('veri sonradan gelince görünür (durum dinlenir)', (
      tester,
    ) async {
      final rig = await _pump(tester, null);
      expect(find.byKey(_root), findsNothing);

      rig.cloud.peaceNotification = _v2();
      await rig.state.fetchPeaceNotification();
      await tester.pump();
      expect(find.byKey(_root), findsOneWidget);
    });
  });

  group('tema, ölçek, erişilebilirlik', () {
    for (final mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final scale in <double>[1.0, 1.5]) {
        testWidgets('${mode.name} / ölçek $scale: üç satır da taşmadan sığar', (
          tester,
        ) async {
          await _pump(
            tester,
            _v2(stale: true, online: 0, total: 3),
            themeMode: mode,
            textScale: scale,
            width: 280,
          );
          expect(find.byKey(_last), findsOneWidget);
          expect(find.byKey(_devices), findsOneWidget);
          expect(find.byKey(_stale), findsOneWidget);
          expect(tester.takeException(), isNull);
          final rect = tester.getRect(find.byKey(_stale));
          expect(rect.right, lessThanOrEqualTo(280));
        });
      }
    }

    testWidgets(
      'Semantics: her satır tek öğe (simge+metin birleşik), okunur etiketle',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pump(tester, _v2(stale: true));

        expect(
          tester.getSemantics(find.byKey(_last)).getSemanticsData().label,
          'Son hatırlatma: Dün 23:30 - açık 2 lamba, 1 panjur (kapatılmadı)',
        );
        expect(
          tester.getSemantics(find.byKey(_devices)).getSemanticsData().label,
          'Cihazlar: 1/2 çevrimiçi',
        );
        expect(
          tester.getSemantics(find.byKey(_stale)).getSemanticsData().label,
          'Cihaz çevrimdışı; açık lamba bilgisi güncel değil.',
        );
        handle.dispose();
      },
    );
  });
}
