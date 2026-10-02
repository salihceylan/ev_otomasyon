import 'dart:async';
import 'dart:math' as math;

import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/peace_banner.dart';
import 'package:ev_otomasyon/ui/dashboard/status_pills.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/settings/child_lock_card.dart';
import 'package:ev_otomasyon/ui/widgets/settings/peace_notification_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/support.dart';
import 'ui/e1_helpers.dart';

/// Çocuk kilidi ve gece huzur bildirimi: **davranış** testleri. Gerçek `AutomationState` (sahte
/// REST/MQTT/saat) üzerinde arayüz dokunuşları, komut gönderimi, cihaz doğrulaması, bilinçli
/// kapatma, yetki kapısı ve erişilebilirlik sınanır.
void main() {
  double contrast(Color a, Color b) {
    final la = a.computeLuminance();
    final lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  Future<void> emitLock(WidgetTester tester, StateHarness h, bool locked) async {
    h.mqtt.emitStateJson(stateJson(childLock: locked));
    await settle(tester);
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  group('Çocuk kilidi kartı: üç durumlu gösterim', () {
    testWidgets('bilinmeyen durum "kilit kapalı" gösterilmez; süre dolunca "alınamadı" ve yeniden dene çıkar',
        (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const ChildLockCard()),
        configure: (h) => h.e1.childLockError = kServerError,
      );

      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      expect(find.text('Durum alınıyor…'), findsOneWidget);
      expect(find.textContaining('Kilit kapalı'), findsNothing);
      expect(tester.widget<Switch>(byKeyName('switch_child_lock')).onChanged, isNull,
          reason: 'durum bilinmeden kilit değiştirilemez');

      h.clock.advance(const Duration(seconds: 9));
      await tester.pump();
      expect(find.textContaining('Durum alınamadı'), findsOneWidget);
      expect(byKeyName('btn_child_lock_retry'), findsOneWidget);

      final before = h.e1.count('getChildLock');
      await tester.tap(byKeyName('btn_child_lock_retry'));
      await settle(tester);
      expect(h.e1.count('getChildLock'), greaterThan(before), reason: 'yeniden dene durumu yeniden sorgular');
    });

    testWidgets('cihaz kilitli bildirince "Kilitli", kapalı bildirince "Kilit kapalı" görünür', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      expect(find.text('Kilit kapalı: duvar anahtarları serbest'), findsOneWidget);

      await emitLock(tester, h, true);
      expect(find.text('Kilitli: duvar anahtarları devre dışı'), findsOneWidget);
      expect(tester.widget<Switch>(byKeyName('switch_child_lock')).value, isTrue);

      await emitLock(tester, h, false);
      expect(find.text('Kilit kapalı: duvar anahtarları serbest'), findsOneWidget);
      expect(tester.widget<Switch>(byKeyName('switch_child_lock')).value, isFalse);
    });

    testWidgets('pano çevrimdışıyken değer "Son bilinen" olarak işaretlenir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      await emitLock(tester, h, true);
      h.mqtt.emitPresence(false);
      await settle(tester);
      expect(find.textContaining('Son bilinen: Kilitli'), findsOneWidget);
    });

    testWidgets('kartın başlığı "Çocuk Kilidi"dir; "Yazılımsal" jargonu yoktur', (tester) async {
      await pumpReady(tester, scaffolded(const ChildLockCard()));
      expect(find.text('Çocuk Kilidi'), findsOneWidget);
      expect(find.textContaining('Yazılımsal'), findsNothing);
    });
  });

  group('Çocuk kilidi: kilitlemek tek dokunuş, kaldırmak bilinçli eylem', () {
    testWidgets('kilitlemek tek dokunuştur; cihaz doğrulayana kadar "Uygulanıyor…" görünür', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));

      await tester.tap(byKeyName('switch_child_lock'));
      await settle(tester);

      expect(h.e1.calls, contains('setChildLock:true'));
      expect(h.state.childLockPending, isTrue);
      expect(find.text('Uygulanıyor…'), findsOneWidget);

      await emitLock(tester, h, true);
      expect(h.state.childLockPending, isFalse);
      expect(find.text('Kilitli: duvar anahtarları devre dışı'), findsOneWidget);
    });

    testWidgets('kilidi kapatmak tek dokunuşla olmaz: doğrulama sayfası açılır, vazgeçilirse komut gitmez',
        (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      await emitLock(tester, h, true);

      await tester.tap(byKeyName('switch_child_lock'));
      await openSheet(tester);

      expect(byKeyName('child_lock_disable_sheet'), findsOneWidget);
      expect(h.e1.calls.where((c) => c.startsWith('setChildLock')), isEmpty,
          reason: 'sayfa açıkken kilit kaldırılmaz');

      await tester.tap(byKeyName('btn_child_lock_cancel'));
      await openSheet(tester);
      expect(byKeyName('child_lock_disable_sheet'), findsNothing);
      expect(h.e1.calls.where((c) => c.startsWith('setChildLock')), isEmpty);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    testWidgets('biyometrik destekleniyorsa kimlik doğrulaması ister; doğrulanınca kilit kaldırılır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()), biometricSupported: true);
      await emitLock(tester, h, true);

      await tester.tap(byKeyName('switch_child_lock'));
      await openSheet(tester);
      expect(byKeyName('btn_child_lock_verify'), findsOneWidget);
      expect(byKeyName('btn_child_lock_hold'), findsNothing, reason: 'biyometrik varken basılı tutma yolu yoktur');

      await tester.tap(byKeyName('btn_child_lock_verify'));
      await openSheet(tester);

      expect(h.biometric.authenticateCalls, 1);
      expect(h.e1.calls, contains('setChildLock:false'));
    });

    testWidgets('kimlik doğrulanamazsa kilit kalkmaz ve açıklama gösterilir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()), biometricSupported: true);
      h.biometric.authResult = false;
      await emitLock(tester, h, true);

      await tester.tap(byKeyName('switch_child_lock'));
      await openSheet(tester);
      await tester.tap(byKeyName('btn_child_lock_verify'));
      await openSheet(tester);

      expect(find.text('Kimlik doğrulanamadı. Çocuk kilidi kaldırılmadı.'), findsOneWidget);
      expect(h.e1.calls.where((c) => c.startsWith('setChildLock')), isEmpty);
      expect(h.state.childLockStatus, ChildLockStatus.locked);
    });

    testWidgets('biyometrik yoksa 1,2 sn basılı tutmak gerekir; erken bırakınca kilit kalkmaz', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      await emitLock(tester, h, true);

      await tester.tap(byKeyName('switch_child_lock'));
      await openSheet(tester);
      expect(byKeyName('btn_child_lock_hold'), findsOneWidget);
      expect(byKeyName('btn_child_lock_verify'), findsNothing);

      // Erken bırakma.
      final early = await tester.startGesture(tester.getCenter(byKeyName('btn_child_lock_hold')));
      await tester.pump(); // ilk kare: animasyon saati başlar
      await tester.pump(const Duration(milliseconds: 500));
      await early.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.e1.calls.where((c) => c.startsWith('setChildLock')), isEmpty);
      expect(byKeyName('child_lock_disable_sheet'), findsOneWidget);

      // Tam süre basılı tutma.
      final hold = await tester.startGesture(tester.getCenter(byKeyName('btn_child_lock_hold')));
      await tester.pump(); // ilk kare: animasyon saati başlar
      await tester.pump(const Duration(milliseconds: 1300));
      await hold.up();
      await openSheet(tester);

      expect(h.e1.calls, contains('setChildLock:false'));
      expect(byKeyName('child_lock_disable_sheet'), findsNothing);
    });
  });

  group('Çocuk kilidi: yetki kapısı (Capabilities.canChangeChildLock)', () {
    testWidgets('geçerli misafir durumu salt-okunur görür; anahtar pasif, açıklama gösterilir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()), home: guestHome());
      await emitLock(tester, h, true);

      expect(find.text('Kilitli: duvar anahtarları devre dışı'), findsOneWidget,
          reason: 'misafir kilidin durumunu görür');
      expect(tester.widget<Switch>(byKeyName('switch_child_lock')).onChanged, isNull);
      expect(byKeyName('text_child_lock_readonly'), findsOneWidget);
    });

    testWidgets('aile üyesi kilidi değiştirebilir (eski "isMember" kara listesi resident\'ı engelliyordu)',
        (tester) async {
      await pumpReady(tester, scaffolded(const ChildLockCard()), role: 'resident');
      expect(tester.widget<Switch>(byKeyName('switch_child_lock')).onChanged, isNotNull);
      expect(byKeyName('text_child_lock_readonly'), findsNothing);
    });

    testWidgets('komut hatası kartta ayrı snackbar çıkarmaz (hata kabuktaki tek aboneye gider)', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const ChildLockCard()),
        configure: (h) => h.e1.setChildLockError = kNetworkError,
      );
      await tester.tap(byKeyName('switch_child_lock'));
      await settle(tester);
      expect(h.state.childLockPending, isFalse, reason: 'ağ hatasında anında geri alınır');
      expect(find.byType(SnackBar), findsNothing, reason: 'widget başına snackbar yok');
    });
  });

  group('Çocuk kilidi: erişilebilirlik ve tema', () {
    testWidgets('durum değişimi ekran okuyucuya duyurulur', (tester) async {
      final announcements = <String>[];
      tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(
        SystemChannels.accessibility,
        (dynamic message) async {
          if (message is Map && message['type'] == 'announce') {
            final data = message['data'];
            if (data is Map) announcements.add('${data['message']}');
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));

      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      await emitLock(tester, h, true);
      await tester.pump();

      expect(announcements.any((m) => m.contains('Çocuk kilidi etkin')), isTrue,
          reason: 'duyurular: $announcements');
    });

    testWidgets('anahtar tek bir birleşik erişilebilirlik düğümünde "Çocuk kilidi" etiketi ve durum taşır',
        (tester) async {
      final handle = tester.ensureSemantics();
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()));
      await emitLock(tester, h, true);

      final node = tester.getSemantics(find.descendant(
        of: byKeyName('card_child_lock'),
        matching: find.byType(MergeSemantics),
      ).first);
      expect(node.label, contains('Çocuk kilidi'));
      expect(node.label, contains('Kilitli'));
      handle.dispose();
    });

    testWidgets('açık temada başlık, durum ve kart AA kontrastındadır (kart rengi koyu sabit değil)', (tester) async {
      final h = await pumpReady(tester, scaffolded(const ChildLockCard()), themeMode: ThemeMode.light);
      await emitLock(tester, h, true);

      final card = tester.widget<Container>(byKeyName('card_child_lock'));
      final cardColor = (card.decoration! as BoxDecoration).color!;
      expect(cardColor, AppTheme.cardLight, reason: 'açık temada kart beyaz olmalı');

      final title = tester.widget<Text>(find.text('Çocuk Kilidi'));
      expect(contrast(title.style!.color!, cardColor), greaterThanOrEqualTo(4.5));

      final status = tester.widget<Text>(byKeyName('text_child_lock_status'));
      expect(contrast(status.style!.color!, cardColor), greaterThanOrEqualTo(4.5),
          reason: 'kilitli durum metni açık temada okunur olmalı');
    });

    testWidgets('yazı ölçeği 1.5 ve dar ekranda kart taşmaz', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const ChildLockCard()),
        size: const Size(320, 640),
        textScale: 1.5,
      );
      await emitLock(tester, h, true);
      expect(tester.takeException(), isNull);
    });
  });

  group('Çocuk kilidi rozeti (pano)', () {
    testWidgets('yalnızca kilitliyken görünür; dokununca açıklayıcı bilgi sayfası açılır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const DashboardStatusBar()));
      expect(byKeyName('chip_child_lock'), findsNothing, reason: 'kilit kapalıyken rozet yok');

      await emitLock(tester, h, true);
      expect(byKeyName('chip_child_lock'), findsOneWidget);
      expect(find.text('Çocuk Kilidi Aktif'), findsOneWidget);

      await tester.tap(byKeyName('chip_child_lock'));
      await openSheet(tester);

      expect(byKeyName('child_lock_info_sheet'), findsOneWidget);
      for (final title in ['Neyi kilitler?', 'Neyi kilitlemez?', 'Elektrik kesintisinde', 'Kapsamı', 'Kim değiştirebilir?']) {
        expect(find.text(title), findsOneWidget, reason: title);
      }
      expect(find.textContaining('elektrik kesilip gelse de sürer'), findsOneWidget);
      expect(find.textContaining('tüm duvar anahtarlarını'), findsOneWidget);

      await tester.tap(byKeyName('btn_child_lock_info_close'));
      await openSheet(tester);
      expect(byKeyName('child_lock_info_sheet'), findsNothing);
    });

    testWidgets('durum bilinmiyorsa rozet "kilitli" iddiası yapmaz', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const DashboardStatusBar()),
        configure: (h) => h.e1.childLockError = kServerError,
      );
      expect(h.state.childLockStatus, ChildLockStatus.unknown);
      expect(byKeyName('chip_child_lock'), findsNothing);
    });

    testWidgets('misafir de kilit rozetini görür (ölü duvar anahtarlarına şaşırmasın)', (tester) async {
      final h = await pumpReady(tester, scaffolded(const DashboardStatusBar()), home: guestHome());
      await emitLock(tester, h, true);
      expect(byKeyName('chip_child_lock'), findsOneWidget);
    });
  });

  group('Gece huzur bildirimi kartı', () {
    testWidgets('sunucunun uzun anahtarları (peace_notification_enabled/_time) doğru okunur', (tester) async {
      await pumpReady(tester, scaffolded(const PeaceNotificationCard()));
      expect(find.text('Açık • saat 23:30'), findsOneWidget);
      expect(tester.widget<Switch>(byKeyName('switch_peace')).value, isTrue);
    });

    testWidgets('durum alınamazsa "Aktif" gösterilmez; yeniden deneyince doğru durum gelir', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const PeaceNotificationCard()),
        configure: (h) => h.e1.peaceGetError = kServerError,
      );
      await settle(tester);
      expect(find.text('Durum alınamadı'), findsOneWidget);
      expect(find.textContaining('Açık'), findsNothing);
      expect(tester.widget<Switch>(byKeyName('switch_peace')).onChanged, isNull);

      h.e1.peaceGetError = null;
      await tester.tap(byKeyName('btn_peace_retry'));
      await settle(tester);
      expect(find.text('Açık • saat 23:30'), findsOneWidget);
    });

    testWidgets('kapatma isteği sunucuya gider ve karta yansır', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceNotificationCard()));
      await tester.tap(byKeyName('switch_peace'));
      await settle(tester);
      expect(h.e1.peaceUpdates.last['enabled'], isFalse);
      expect(find.text('Kapalı'), findsOneWidget);
    });

    testWidgets('kaydetme hatası yakalanır; ham istisna değil Türkçe mesaj gösterilir', (tester) async {
      final h = await pumpReady(
        tester,
        scaffolded(const PeaceNotificationCard()),
        configure: (h) => h.e1.peaceUpdateError = kServerError,
      );
      await tester.tap(byKeyName('switch_peace'));
      await settle(tester);
      expect(find.text(kServerError.message), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(h.e1.peaceUpdates, isEmpty);
    });

    testWidgets('açık lamba varsa "Hepsini Kapat" gerçek sonuç sayısını bildirir ve çalışırken pasiftir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceNotificationCard()), endpoints: litEndpoints());
      h.e1.closeAllGate = Completer<void>();
      expect(find.text('Şu an evde 3 lamba açık'), findsOneWidget);

      await tester.tap(byKeyName('btn_close_all_lights'));
      await tester.pump();
      expect(find.text('Kapatılıyor…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(byKeyName('btn_close_all_lights')).onPressed, isNull);

      h.e1.closeAllResponse = <String, dynamic>{'closed_count': 3};
      h.e1.closeAllGate!.complete();
      await settle(tester);
      expect(find.text('3 açık lamba için kapatma komutu gönderildi.'), findsOneWidget);
      expect(find.text('Kapatılıyor…'), findsNothing);
    });

    testWidgets('"Hepsini Kapat" hatası yakalanır; düğme yeniden etkinleşir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceNotificationCard()), endpoints: litEndpoints());
      h.e1.closeAllError = kNetworkError;
      await tester.tap(byKeyName('btn_close_all_lights'));
      await settle(tester);
      expect(find.text(kNetworkError.message), findsOneWidget);
      expect(tester.widget<OutlinedButton>(byKeyName('btn_close_all_lights')).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('Pano huzur bandı', () {
    testWidgets('açık lamba sayısını gösterir; "Hepsini Kapat" kapatılan gerçek sayıyı bildirir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceBanner()), endpoints: litEndpoints());
      expect(find.text('Huzur Modu / Gece Kontrolü'), findsOneWidget);
      expect(find.text('3 lamba açık kaldı.'), findsOneWidget);

      h.e1.closeAllResponse = <String, dynamic>{'closed_count': 2};
      await tester.tap(byKeyName('btn_close_all_lights'));
      await settle(tester);
      expect(find.text('2 açık lamba için kapatma komutu gönderildi.'), findsOneWidget);
    });

    testWidgets('açık lamba yoksa band görünmez', (tester) async {
      await pumpReady(tester, scaffolded(const PeaceBanner()));
      expect(byKeyName('banner_peace'), findsNothing);
    });

    testWidgets('sunucu 0 kapatılan derse "açık lamba bulunamadı" denir', (tester) async {
      final h = await pumpReady(tester, scaffolded(const PeaceBanner()), endpoints: litEndpoints());
      h.e1.closeAllResponse = <String, dynamic>{'closed_count': 0};
      await tester.tap(byKeyName('btn_close_all_lights'));
      await settle(tester);
      expect(find.text('Kapatılacak açık lamba bulunamadı.'), findsOneWidget);
    });
  });
}
