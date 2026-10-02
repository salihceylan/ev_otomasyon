import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show SemanticsAction;

import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/push_status_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'peace_ui_rig.dart';

/// `PushStatusTile`: ayar kartına tek satırla konan push durumu (gerçek denetleyici + sahte push).

const _tile = Key('tile_push_status');
const _text = Key('text_push_status');
const _enable = Key('btn_push_enable');
const _retry = Key('btn_push_retry');

const _registeredText = 'Bu telefona bildirim gönderilecek.';
const _registeringText = 'Bildirimler etkinleştiriliyor…';
const _needsText = 'Gece hatırlatmasını almak için bildirimleri açın.';
const _deniedText =
    'Bildirim izni kapalı. Hatırlatmayı almak için telefon ayarlarından bu uygulamanın bildirimlerini açın.';
const _failedText =
    'Bildirim kaydı şu an yapılamadı. Otomatik olarak yeniden denenecek.';
const _blockedText =
    'Bildirim kaydı bu cihazda kabul edilmedi. Çıkış yapıp yeniden giriş yapmayı deneyin.';
const _unsupportedText =
    'Bu sürümde bildirim telefona gönderilmez; uygulamayı açtığınızda hatırlatma görünür.';

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Ayar kartını taklit eden bağlam: dar bir kart içinde TEK satır `const PushStatusTile()`.
Future<PeaceUiRig> _pumpTile(
  WidgetTester tester, {
  String role = 'owner',
  PushState state = PushState.registered,
  bool denied = false,
  bool blocked = false,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  double width = 320,
}) async {
  usePhone(tester, size: Size(width, 700));
  final rig = PeaceUiRig.create(role: role, startState: state);
  addTearDown(rig.dispose);
  rig.push
    ..denied = denied
    ..blocked = blocked;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: child!,
      ),
      home: ChangeNotifierProvider<PeaceNoticeController>.value(
        value: rig.controller,
        child: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Builder(
                builder: (ctx) => Container(
                  padding: const EdgeInsets.all(16),
                  decoration: AppTheme.cardDecoration(ctx, radius: 16),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [Text('Gece Huzur Bildirimi'), PushStatusTile()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // push.start -> durum olayı
  await tester.pump();
  return rig;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('durumlar ve metinler', () {
    testWidgets(
      'unsupported + uygun (owner): dürüst bilgi satırı çizilir, eylem yok',
      (tester) async {
        final rig = await _pumpTile(tester, state: PushState.unsupported);
        expect(rig.controller.pushState, PushState.unsupported);
        expect(rig.controller.isEligible, isTrue);
        expect(find.byKey(_tile), findsOneWidget);
        expect(find.byKey(_text), findsOneWidget);
        expect(find.text(_unsupportedText), findsOneWidget);
        expect(find.byIcon(Icons.info_outline), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
        expect(find.byKey(_retry), findsNothing);
        expect(find.byType(TextButton), findsNothing);
      },
    );

    testWidgets('unsupported + uygun (resident): aynı dürüst satır çizilir', (
      tester,
    ) async {
      final rig = await _pumpTile(
        tester,
        role: 'resident',
        state: PushState.unsupported,
      );
      expect(rig.controller.isEligible, isTrue);
      expect(rig.controller.pushState, PushState.unsupported);
      expect(find.text(_unsupportedText), findsOneWidget);
      expect(find.byKey(_tile), findsOneWidget);
    });

    testWidgets('unsupported ama uygun DEĞİL (misafir): hiçbir şey çizilmez', (
      tester,
    ) async {
      final rig = await _pumpTile(
        tester,
        role: 'guest',
        state: PushState.unsupported,
      );
      // Misafir uygun olmadığı için koordinatör başlatılmaz; gerçek koordinatör uygunluk kaybından sonra da
      // `unsupported` kalır: bu durum sahte koordinatörde elle üretilir.
      rig.push.emitState(PushState.unsupported);
      await tester.pump();
      await tester.pump();
      expect(rig.controller.isEligible, isFalse);
      expect(rig.controller.pushState, PushState.unsupported);
      expect(find.byKey(_tile), findsNothing);
      expect(find.byKey(_text), findsNothing);
      expect(find.text(_unsupportedText), findsNothing);
    });

    testWidgets('idle: uygun oturumda bile hiçbir şey çizilmez', (
      tester,
    ) async {
      final rig = await _pumpTile(tester, state: PushState.idle);
      expect(rig.controller.pushState, PushState.idle);
      expect(rig.controller.isEligible, isTrue);
      expect(find.byKey(_tile), findsNothing);
      expect(find.text(_unsupportedText), findsNothing);
    });

    testWidgets(
      'registered: "Bu telefona bildirim gönderilecek." ve eylem yok',
      (tester) async {
        await _pumpTile(tester, state: PushState.registered);
        expect(find.text(_registeredText), findsOneWidget);
        expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
      },
    );

    testWidgets(
      'registering: "Bildirimler etkinleştiriliyor…", eylem yok, sonsuz animasyon yok',
      (tester) async {
        await _pumpTile(tester, state: PushState.registering);
        expect(find.text(_registeringText), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        await tester.pumpAndSettle(); // zaman aşımı olmamalı
      },
    );

    testWidgets('needsPermission: yönlendirici metin + "Bildirimleri aç"', (
      tester,
    ) async {
      await _pumpTile(tester, state: PushState.needsPermission);
      expect(find.text(_needsText), findsOneWidget);
      expect(find.text('Bildirimleri aç'), findsOneWidget);
      expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    });

    testWidgets(
      'needsPermission + reddedilmiş: sistem ayarlarına yönlendiren metin, düğme YOK',
      (tester) async {
        final rig = await _pumpTile(
          tester,
          state: PushState.needsPermission,
          denied: true,
        );
        expect(rig.controller.pushPermissionDenied, isTrue);
        expect(find.text(_deniedText), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
      },
    );

    testWidgets(
      'failed + GEÇİCİ: otomatik yeniden denenecek metni, düğme yok',
      (tester) async {
        final rig = await _pumpTile(tester, state: PushState.failed);
        expect(rig.controller.pushRegistrationBlocked, isFalse);
        expect(find.text(_failedText), findsOneWidget);
        expect(find.byIcon(Icons.error_outline), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
        expect(find.byKey(_retry), findsNothing);
      },
    );

    testWidgets(
      'failed + KALICI RED: dürüst metin (otomatik yeniden deneme YOK) ve "Yeniden dene" düğmesi',
      (tester) async {
        final rig = await _pumpTile(
          tester,
          state: PushState.failed,
          blocked: true,
        );
        expect(rig.controller.pushRegistrationBlocked, isTrue);
        expect(find.text(_blockedText), findsOneWidget);
        expect(
          find.textContaining('yeniden denenecek'),
          findsNothing,
          reason: 'kalıcı redde "otomatik denenecek" denmez',
        );
        expect(find.byKey(_retry), findsOneWidget);
        expect(find.text('Yeniden dene'), findsOneWidget);
        expect(find.byKey(_enable), findsNothing);
      },
    );

    testWidgets(
      '"Yeniden dene" denetleyicinin retryPushRegistration işlevini çağırır; kayıt sürerken metin güncellenir',
      (tester) async {
        final rig = await _pumpTile(
          tester,
          state: PushState.failed,
          blocked: true,
        );
        rig.push.stateAfterRetry = PushState.registering;

        await tester.tap(find.byKey(_retry));
        await tester.pump();
        await tester.pump();

        expect(rig.push.calls, contains('retry'));
        expect(
          rig.push.calls,
          isNot(contains('request')),
          reason: 'izin penceresi açılmaz',
        );
        expect(find.text(_registeringText), findsOneWidget);
        expect(find.text(_blockedText), findsNothing);
        expect(find.byKey(_retry), findsNothing);
      },
    );

    testWidgets(
      'yeniden deneme yine reddedilirse düğme kalır ve istek bitince yeniden etkindir',
      (tester) async {
        final rig = await _pumpTile(
          tester,
          state: PushState.failed,
          blocked: true,
        );
        await tester.tap(find.byKey(_retry));
        await tester.pump();
        rig.push.blocked = true;
        rig.push.emitState(PushState.registering);
        await tester.pump();
        await tester.pump();
        rig.push.emitState(PushState.failed);
        await tester.pump();
        await tester.pump();
        expect(find.text(_blockedText), findsOneWidget);
        expect(find.byKey(_retry), findsOneWidget);
        expect(
          tester.widget<TextButton>(find.byKey(_retry)).onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('geçici -> kalıcı red geçişinde metin ve düğme güncellenir', (
      tester,
    ) async {
      final rig = await _pumpTile(tester, state: PushState.failed);
      expect(find.text(_failedText), findsOneWidget);
      rig.push.blocked = true;
      rig.push.emitState(PushState.registering);
      await tester.pump();
      rig.push.emitState(PushState.failed);
      await tester.pump();
      await tester.pump();
      expect(find.text(_blockedText), findsOneWidget);
      expect(find.byKey(_retry), findsOneWidget);
    });

    testWidgets(
      'durum değişince metin güncellenir (needsPermission -> registered)',
      (tester) async {
        final rig = await _pumpTile(tester, state: PushState.needsPermission);
        expect(find.text(_needsText), findsOneWidget);

        rig.push.emitState(PushState.registered);
        await tester.pump();
        await tester.pump();
        expect(find.text(_needsText), findsNothing);
        expect(find.text(_registeredText), findsOneWidget);

        rig.push.emitState(PushState.unsupported);
        await tester.pump();
        await tester.pump();
        expect(find.text(_registeredText), findsNothing);
        expect(find.text(_unsupportedText), findsOneWidget);

        rig.push.emitState(PushState.idle);
        await tester.pump();
        await tester.pump();
        expect(find.byKey(_tile), findsNothing);
      },
    );
  });

  group('eylem', () {
    testWidgets(
      '"Bildirimleri aç" denetleyicinin requestPermission\'ını çağırır (izin istenir)',
      (tester) async {
        final rig = await _pumpTile(tester, state: PushState.needsPermission);

        await tester.tap(find.byKey(_enable));
        await tester.pump();
        await tester.pump();

        expect(rig.push.calls, contains('request'));
        expect(
          rig.store.prompted,
          isTrue,
          reason: 'denetleyici istemi soruldu diye kalıcılaştırır',
        );
        expect(
          find.text(_registeredText),
          findsOneWidget,
          reason: 'izin verilince kayıtlı durumuna geçer',
        );
      },
    );

    testWidgets('izin reddedilirse yönlendirici metne geçer', (tester) async {
      final rig = await _pumpTile(tester, state: PushState.needsPermission);
      rig.push
        ..deniedAfterRequest = true
        ..stateAfterRequest = PushState.needsPermission;

      await tester.tap(find.byKey(_enable));
      await tester.pump();
      await tester.pump();

      expect(find.text(_deniedText), findsOneWidget);
      expect(find.byKey(_enable), findsNothing);
    });

    testWidgets('istek sürerken düğme devre dışı: çift dokunuş tek istek', (
      tester,
    ) async {
      final rig = await _pumpTile(tester, state: PushState.needsPermission);
      rig.push.requestGate = Completer<void>();
      rig.push.stateAfterRequest = PushState.needsPermission;

      await tester.tap(find.byKey(_enable));
      await tester.pump();
      expect(tester.widget<TextButton>(find.byKey(_enable)).onPressed, isNull);
      await tester.tap(find.byKey(_enable), warnIfMissed: false);
      await tester.pump();
      expect(rig.push.calls.where((c) => c == 'request'), hasLength(1));

      rig.push.requestGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(
        tester.widget<TextButton>(find.byKey(_enable)).onPressed,
        isNotNull,
      );
    });
  });

  group('tema, ölçek, erişilebilirlik', () {
    final states = <(PushState, bool, bool)>[
      (PushState.unsupported, false, false),
      (PushState.registered, false, false),
      (PushState.registering, false, false),
      (PushState.needsPermission, false, false),
      (PushState.needsPermission, true, false),
      (PushState.failed, false, false),
      (PushState.failed, false, true),
    ];
    for (final mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      for (final (state, denied, blocked) in states) {
        final label =
            '${mode.name} / ${state.name}${denied ? ' (reddedildi)' : ''}${blocked ? ' (kalıcı red)' : ''}';
        testWidgets(
          '$label: metin ve düğme AA (>= 4.5:1) kontrastlı, simge >= 3:1',
          (tester) async {
            await _pumpTile(
              tester,
              state: state,
              denied: denied,
              blocked: blocked,
              themeMode: mode,
            );
            final ctx = tester.element(find.byKey(_tile));
            final card = AppTheme.getCardColor(ctx);
            final text = tester.widget<Text>(find.byKey(_text));
            expect(
              _contrast(text.style!.color!, card),
              greaterThanOrEqualTo(4.5),
              reason: 'durum metni',
            );
            final icon = tester.widget<Icon>(
              find.descendant(
                of: find.byKey(_tile),
                matching: find.byType(Icon),
              ),
            );
            expect(
              _contrast(icon.color!, card),
              greaterThanOrEqualTo(3.0),
              reason: 'durum simgesi',
            );
            for (final key in <Key>[_enable, _retry]) {
              if (find.byKey(key).evaluate().isEmpty) continue;
              final style = tester.widget<TextButton>(find.byKey(key)).style!;
              expect(
                _contrast(
                  style.foregroundColor!.resolve(<WidgetState>{})!,
                  card,
                ),
                greaterThanOrEqualTo(4.5),
                reason: 'düğme metni $key',
              );
            }
          },
        );

        testWidgets('$label / 1.5 ölçek: taşma yok', (tester) async {
          await _pumpTile(
            tester,
            state: state,
            denied: denied,
            blocked: blocked,
            themeMode: mode,
            textScale: 1.5,
            width: 280,
          );
          expect(find.byKey(_tile), findsOneWidget);
          expect(tester.takeException(), isNull);
          // Metin kartın içinde kalır (yatay taşma yok).
          final text = tester.getRect(find.byKey(_text));
          expect(text.right, lessThanOrEqualTo(280));
          expect(text.left, greaterThanOrEqualTo(0));
        });
      }
    }

    testWidgets('düğme dokunma hedefi en az 48 dp', (tester) async {
      await _pumpTile(tester, state: PushState.needsPermission);
      final size = tester.getSize(find.byKey(_enable));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(size.width, greaterThanOrEqualTo(48));
    });

    testWidgets('durum simge + metinle verilir (renge bağımlı değil)', (
      tester,
    ) async {
      for (final entry in <PushState, IconData>{
        PushState.unsupported: Icons.info_outline,
        PushState.registered: Icons.check_circle_outline,
        PushState.registering: Icons.sync,
        PushState.needsPermission: Icons.notifications_off_outlined,
        PushState.failed: Icons.error_outline,
      }.entries) {
        await _pumpTile(tester, state: entry.key);
        expect(
          find.descendant(
            of: find.byKey(_tile),
            matching: find.byIcon(entry.value),
          ),
          findsOneWidget,
          reason: '${entry.key}',
        );
        expect(
          find.descendant(of: find.byKey(_tile), matching: find.byType(Text)),
          findsWidgets,
        );
      }
    });

    testWidgets(
      'Semantics: durum metni canlı bölge, düğme etiketli ve dokunulabilir',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpTile(tester, state: PushState.needsPermission);

        final text = tester.getSemantics(find.byKey(_text)).getSemanticsData();
        expect(text.label, _needsText);
        expect(text.flagsCollection.isLiveRegion, isTrue);

        final button = tester
            .getSemantics(find.byKey(_enable))
            .getSemanticsData();
        expect(button.label, 'Bildirimleri aç');
        expect(button.flagsCollection.isButton, isTrue);
        expect(button.hasAction(SemanticsAction.tap), isTrue);
        handle.dispose();
      },
    );

    testWidgets(
      'Semantics: bilgi satırı (unsupported) canlı bölge olarak okunur, düğmesizdir',
      (tester) async {
        final handle = tester.ensureSemantics();
        await _pumpTile(tester, state: PushState.unsupported);

        final text = tester.getSemantics(find.byKey(_text)).getSemanticsData();
        expect(text.label, _unsupportedText);
        expect(text.flagsCollection.isLiveRegion, isTrue);
        expect(find.byType(TextButton), findsNothing);
        handle.dispose();
      },
    );
  });
}
