import 'dart:io';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/models/scheduled_rule_model.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/app_shell.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Uygulama kabuğu: komut hatalarının **tek** abonesi, "Tekrar dene", oturum olayları ve tema.
void main() {
  setUpAll(() {
    // Testte ağdan yazı tipi indirilmez.
    GoogleFonts.config.allowRuntimeFetching = false;
  });

  const lamp = RelayItem(id: 1, name: 'Avize', type: 0, state: false);

  /// İki sayfalı sınama uygulaması: ana sayfada bir röle kartı ve "ikinci sayfa" düğmesi.
  Widget home() => Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              const RelaySwitchCard(relay: lamp),
              ElevatedButton(
                key: const Key('btn_open_second'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('İkinci sayfa', key: Key('second_page'))),
                  ),
                ),
                child: const Text('aç'),
              ),
            ],
          ),
        ),
      );

  Future<StateHarness> pumpShell(
    WidgetTester tester, {
    String role = 'owner',
    HomeModel? homeModel,
    void Function(StateHarness h)? configure,
  }) async {
    final h = (await tester.runAsync(() => e1Ready(role: role, home: homeModel, configure: configure)))!;
    addTearDown(h.dispose);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AutomationState>.value(
        value: h.state,
        child: AppShell(home: home()),
      ),
    );
    await tester.pump();
    return h;
  }

  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('Komut hataları: kabuktaki TEK abone', () {
    testWidgets('geri alınan komut CommandFailure.message ile tek bir snackbar olarak gösterilir', (tester) async {
      final h = await pumpShell(tester);
      h.e1.sendCommandHandler = (home, device, command) async => throw const ApiException(
            statusCode: 409,
            code: 'DEVICE_OFFLINE',
            message: 'ham sunucu metni',
          );

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);

      expect(byKeyName('snack_command_failure'), findsOneWidget);
      expect(find.text('Cihaz çevrimdışı. Komut iletilemedi.'), findsOneWidget);
      expect(find.text('ham sunucu metni'), findsNothing, reason: 'sunucu metni değil istemci mesajı gösterilir');
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('yeniden denenebilir hatada "Tekrar dene" aynı komutu yeniden gönderir', (tester) async {
      final h = await pumpShell(tester);
      var fail = true;
      h.e1.sendCommandHandler = (home, device, command) async {
        if (fail) throw kNetworkError;
        return CommandResult(delivered: true, deviceOnline: true, commandId: command['id'] as String?);
      };

      await tester.tap(byKeyName('card_relay_1'));
      await tester.pumpAndSettle(); // snackbar girişi tamamlanır
      expect(find.text('Tekrar dene'), findsOneWidget);
      final sentBefore = h.e1.sentCommands.length;

      fail = false;
      await tester.tap(find.text('Tekrar dene'));
      await flush(tester);

      expect(h.e1.sentCommands.length, sentBefore + 1);
      expect(h.e1.sentCommands.last, containsPair('relay', 1));
      expect(h.e1.sentCommands.last, containsPair('state', true));
    });

    testWidgets('yetki hatasında "Tekrar dene" sunulmaz', (tester) async {
      final h = await pumpShell(tester);
      h.e1.sendCommandHandler = (home, device, command) async => throw ApiException.forbidden();

      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);

      expect(byKeyName('snack_command_failure'), findsOneWidget);
      expect(find.text('Tekrar dene'), findsNothing);
    });

    testWidgets('onay gelmeyen komutun zaman aşımı mesajı gösterilir ve tek snackbar kalır', (tester) async {
      final h = await pumpShell(tester);
      await tester.tap(byKeyName('card_relay_1'));
      await flush(tester);
      h.clock.advance(const Duration(seconds: 3));
      await flush(tester);

      expect(find.textContaining('Cihazdan onay alınamadı'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
    });

    test('mimari kural: commandFailures akışına yalnızca uygulama kabuğu abone olur', () {
      final offenders = <String>[];
      for (final entity in Directory('lib/ui').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final text = entity.readAsStringSync();
        if (text.contains('commandFailures') && !entity.path.replaceAll('\\', '/').endsWith('lib/ui/app_shell.dart')) {
          // Yalnızca yorum satırı olarak anılmış olabilir; kod kullanımı aranır.
          final codeUse = text
              .split('\n')
              .where((l) => l.contains('commandFailures') && !l.trimLeft().startsWith('//') && !l.trimLeft().startsWith('///'))
              .isNotEmpty;
          if (codeUse) offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'widget başına komut hatası aboneliği yok: $offenders');
    });
  });

  group('Oturum olayları', () {
    testWidgets('oturum süresi dolunca açık sayfalar kapanır; bulut modunda mesajı giriş ekranı gösterir (kabuk yinelemez)',
        (tester) async {
      final h = await pumpShell(tester);
      await tester.tap(byKeyName('btn_open_second'));
      await tester.pumpAndSettle();
      expect(byKeyName('second_page'), findsOneWidget);

      h.cloud.onSessionExpired?.call(SessionEndReason.refreshRejected);
      await tester.pump();
      await tester.pumpAndSettle();

      expect(byKeyName('second_page'), findsNothing, reason: 'tüm sayfalar kapanır (giriş kapısı ekranı gösterir)');
      expect(h.state.authStatus, AuthStatus.unauthenticated);
      expect(h.state.sessionNotice, 'Oturumunuz sona erdi. Lütfen tekrar giriş yapın.',
          reason: 'mesaj giriş ekranı için korunur');
      expect(byKeyName('snack_session_notice'), findsNothing, reason: 'giriş ekranı varken kabuk snackbar yinelemez');
    });

    testWidgets('servis oturumunun süresi dolunca ilgili Türkçe mesaj korunur', (tester) async {
      final h = await pumpShell(tester);
      h.cloud.onSessionExpired?.call(SessionEndReason.serviceSessionExpired);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(h.state.sessionNotice, contains('Servis oturumunuzun süresi doldu'));
    });

    testWidgets('misafir süresi dolunca "Erişiminiz sona erdi" diyaloğu çıkar ve ev listesi yenilenir', (tester) async {
      final h = await pumpShell(tester, homeModel: guestHome(hours: 1, name: 'Yazlık'));
      await tester.tap(byKeyName('btn_open_second'));
      await tester.pumpAndSettle();
      final listCalls = h.e1.count('fetchHomes');

      h.clock.advance(const Duration(hours: 2));
      await tester.pump();
      await tester.pumpAndSettle();

      expect(byKeyName('dialog_guest_expired'), findsOneWidget);
      expect(find.textContaining('Yazlık için misafir erişim süreniz doldu'), findsOneWidget);
      expect(byKeyName('second_page'), findsNothing);
      expect(h.e1.count('fetchHomes'), greaterThan(listCalls), reason: 'ev listesi sunucudan tazelenir');
      expect(h.state.authStatus, AuthStatus.authenticated, reason: 'oturum kapanmaz, yalnızca ev erişimi');

      await tester.tap(byKeyName('btn_guest_expired_ok'));
      await tester.pumpAndSettle();
      expect(byKeyName('dialog_guest_expired'), findsNothing);
    });

    testWidgets('güvenli depolama hatası kullanıcıya bir kez bildirilir ve temizlenir', (tester) async {
      final h = await pumpShell(tester);
      h.storage.memory.failWrites = true;
      // Depolama yazımı gerçek asenkron bölgede çalışır (yeniden deneme beklemeleri olabilir).
      await tester.runAsync(() => h.state.setLocalKey('abcdefgh1234'));
      await flush(tester);

      expect(byKeyName('snack_storage_error'), findsOneWidget);
      expect(h.state.storageError, isNull);
    });
  });

  group('Kök uygulama yeniden kurulmaz', () {
    testWidgets('durum değişimleri MaterialApp\'i yeniden kurmaz; yalnızca tema modu değişince kurulur', (tester) async {
      final h = await pumpShell(tester);
      final before = tester.widget<MaterialApp>(find.byType(MaterialApp));

      h.state.setScheduledRulesForTesting(const <ScheduledRule>[]);
      h.mqtt.emitStateJson(stateJson(relays: <int, bool>{1: true}));
      await flush(tester);
      expect(identical(tester.widget<MaterialApp>(find.byType(MaterialApp)), before), isTrue,
          reason: 'her durum bildiriminde kök yeniden kurulmamalı');

      await h.state.setThemeMode(ThemeMode.light);
      await flush(tester);
      expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode, ThemeMode.light);
    });
  });
}
