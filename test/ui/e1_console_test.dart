import 'dart:async';

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/dashboard/console_dashboards.dart';
import 'package:ev_otomasyon/ui/dashboard/endpoint_sections.dart' show SectionHeader;
import 'package:ev_otomasyon/ui/motion/motion.dart';
import 'package:ev_otomasyon/ui/pages/dashboard_page.dart';
import 'package:ev_otomasyon/ui/theme/tokens.dart';
import 'package:ev_otomasyon/ui/widgets/orb/orb.dart';
import 'package:ev_otomasyon/ui/widgets/surface_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// Süper yönetici ve yetkili servis konsolları: sayaçlar gerçekten yüklenir ("—" yüklenmemişse),
/// sabit altyapı satırı ve sabit yedek ad/e-posta yoktur.
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('Sayaç ayrıştırma', () {
    test('sunucunun iç içe özet yanıtı (users/devices/homes) çözülür', () {
      final counts = ConsoleCounts.fromSummary(<String, dynamic>{
        'users': <String, dynamic>{'service_users': 3, 'super_users': 2},
        'devices': <String, dynamic>{'total_devices': 40, 'commissioned_devices': 18},
        'homes': <String, dynamic>{'total_homes': 20},
      });
      expect(counts.serviceManagers, 3);
      expect(counts.superUsers, 2);
      expect(counts.devices, 40);
      expect(counts.commissioned, 18);
      expect(counts.homes, 20);
    });

    test('eski düz anahtarlar yedek olarak okunur; eksik alan "bilinmiyor" (null) kalır, 0 uydurulmaz', () {
      final counts = ConsoleCounts.fromSummary(<String, dynamic>{
        'total_service_managers': 4,
        'total_devices': 9,
      });
      expect(counts.serviceManagers, 4);
      expect(counts.devices, 9);
      expect(counts.commissioned, isNull);
      expect(counts.superUsers, isNull);
    });
  });

  group('Süper yönetici konsolu', () {
    Future<StateHarness> pumpSuper(WidgetTester tester, {void Function(StateHarness h)? configure}) =>
        pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', configure: configure);

    testWidgets('sayaçlar sunucudan gerçekten yüklenir', (tester) async {
      final h = await pumpSuper(tester);
      await flush(tester);

      expect(h.e1.count('getServiceSummary'), 1);
      expect(find.descendant(of: byKeyName('card_metric_service_managers'), matching: find.text('3')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_commissioned'), matching: find.text('18')), findsOneWidget);
      expect(byKeyName('banner_counters_error'), findsNothing);
    });

    testWidgets('yüklenene kadar yükleniyor göstergesi, yüklenemezse "—" ve yeniden dene; sonra gerçek sayılar', (tester) async {
      final h = await pumpSuper(tester, configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);

      expect(byKeyName('banner_counters_error'), findsOneWidget);
      expect(find.text(kServerError.message), findsOneWidget);
      for (final key in ['card_metric_service_managers', 'card_metric_devices', 'card_metric_commissioned']) {
        expect(find.descendant(of: byKeyName(key), matching: find.text('—')), findsOneWidget, reason: key);
      }
      expect(find.text('0'), findsNothing, reason: 'yüklenmemiş sayaç 0 gösterilmez');

      h.e1.summaryError = null;
      await tester.tap(byKeyName('btn_retry'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(byKeyName('banner_counters_error'), findsNothing);
    });

    testWidgets('yükleme sürerken sayaç kartlarında ilerleme gösterilir (sahte "0" yok); yanıt gelince sayılar', (tester) async {
      final gate = Completer<void>();
      final h = await pumpSuper(tester, configure: (h) => h.e1.summaryGate = gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await flush(tester);

      // Neon Glass: dönen gösterge yerine iskelet (Skeleton); sayı yerinde sahte "0"/"—" yok.
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.byType(Skeleton)), findsOneWidget);
      expect(
        find.descendant(of: byKeyName('card_metric_devices'), matching: find.byType(CircularProgressIndicator)),
        findsNothing,
      );
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('—')), findsNothing);
      expect(find.text('0'), findsNothing);

      gate.complete();
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('40')), findsOneWidget);
      expect(h.e1.count('getServiceSummary'), 1);
    });

    testWidgets('sabit altyapı satırı (Port 5000 / PostgreSQL 5434 / EMQX) ve sabit yedek ad/e-posta YOKTUR', (tester) async {
      final h = await pumpSuper(tester);
      h.state.setCurrentUserForTesting(const UserModel(id: 'su', email: '', fullName: '', role: 'super_user'));
      await flush(tester);

      expect(find.textContaining('5000'), findsNothing);
      expect(find.textContaining('5434'), findsNothing);
      expect(find.textContaining('PostgreSQL'), findsNothing);
      expect(find.textContaining('EMQX'), findsNothing);
      expect(find.textContaining('salihceylan'), findsNothing);
      expect(find.textContaining('Salih Ceylan'), findsNothing);
      expect(find.text('Süper Yönetici'), findsWidgets, reason: 'adı olmayan kullanıcı için genel başlık');
    });

    testWidgets('gerçek kullanıcı adı ve e-postası başlık kartında gösterilir', (tester) async {
      await pumpSuper(tester);
      expect(
        find.descendant(of: byKeyName('card_console_header'), matching: find.text('Ayşe Yılmaz')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: byKeyName('card_console_header'), matching: find.text('ayse@example.test')),
        findsOneWidget,
      );
    });

    testWidgets('hızlı işlemler yetkilere göre listelenir (envanter, sorumlular, aboneler, doktor)', (tester) async {
      await pumpSuper(tester);
      for (final key in ['card_action_inventory', 'card_action_service_managers', 'card_action_subscribers', 'card_action_doctor']) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      expect(byKeyName('card_action_commissioning'), findsNothing, reason: 'saha araçları süper kullanıcıya ait değil');
    });
  });

  group('Yetkili servis konsolu', () {
    Future<StateHarness> pumpService(WidgetTester tester, {void Function(StateHarness h)? configure}) =>
        pumpReady(tester, const DashboardPage(), role: 'service_user', globalRole: 'service_user', configure: configure);

    testWidgets('sayaçlar kendi kapsamından (stok + aboneler) yüklenir; süper özet ucu çağrılmaz', (tester) async {
      final h = await pumpService(tester);
      await flush(tester);

      expect(h.e1.count('getServiceSummary'), 0, reason: 'servis personeli yönetici özetini çağıramaz');
      expect(h.e1.count('fetchDeviceInventory'), 1);
      expect(h.e1.count('fetchServiceSubscribers'), 1);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('5')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_commissioned'), matching: find.text('2')), findsOneWidget);
    });

    testWidgets('yüklenemezse "—" ve yeniden dene; uydurma "0" yok', (tester) async {
      final h = await pumpService(tester, configure: (h) => h.e1.inventoryError = kServerError);
      await flush(tester);

      expect(byKeyName('banner_counters_error'), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('—')), findsOneWidget);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('0')), findsNothing);

      h.e1.inventoryError = null;
      await tester.tap(byKeyName('btn_retry'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('card_metric_devices'), matching: find.text('5')), findsOneWidget);
    });

    testWidgets('saha görevleri: servis modu, aboneler, pano değişimi, Wi-Fi kurtarma ve acil sıfırlama (canEmergencyReset)',
        (tester) async {
      await pumpService(tester);
      for (final key in [
        'card_action_commissioning',
        'card_action_subscribers',
        'card_action_replace_board',
        'card_action_wifi_recovery',
        'card_action_emergency_reset',
      ]) {
        expect(byKeyName(key), findsOneWidget, reason: key);
      }
      expect(byKeyName('card_action_inventory'), findsNothing, reason: 'envanter yönetimi yalnızca süper kullanıcı');
      expect(byKeyName('card_action_service_managers'), findsNothing);
      expect(byKeyName('btn_open_service_management'), findsNothing, reason: '"Tüm Paneli Aç" yalnızca süper konsolda');
      expect(byKeyName('notice_service_safety'), findsOneWidget);
    });

    testWidgets('sabit servis e-postası yedeği ve sabit "8 röle / 8 giriş" metni yoktur', (tester) async {
      final h = await pumpService(tester);
      h.state.setCurrentUserForTesting(const UserModel(id: 'sv', email: '', fullName: '', role: 'service_user'));
      await flush(tester);
      expect(find.textContaining('servis@gudeteknoloji'), findsNothing);
      expect(find.textContaining('8 röle'), findsNothing);
      expect(find.textContaining('8 Röle'), findsNothing);
      expect(find.text('Yetkili Servis Sorumlusu'), findsWidgets);
    });
  });

  // ---------------------------------------------------------------------------------------------
  // WP-F3: yerleşim (eşit yükseklik, yetim hücre yok, büyük yazı, tek vurgulu kart, menü ipucu)
  // ---------------------------------------------------------------------------------------------
  group('Konsol yerleşimi (WP-F3)', () {
    Rect rectOf(WidgetTester tester, Finder f) => tester.getRect(f);
    Rect cardRect(WidgetTester tester, String key) => tester.getRect(byKeyName(key));

    testWidgets('telefonda 3 sayaç: ilk iki kart yan yana EŞİT yükseklikte, SON kart tam genişlikte (yetim hücre yok)',
        (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'super_user', size: const Size(360, 1200));
      await flush(tester);
      final a = cardRect(tester, 'card_metric_service_managers');
      final b = cardRect(tester, 'card_metric_devices');
      final c = cardRect(tester, 'card_metric_commissioned');
      final header = cardRect(tester, 'card_console_header');

      expect(a.top, closeTo(b.top, 0.5));
      expect(a.height, closeTo(b.height, 0.5), reason: 'satırdaki kartlar eşit yükseklikte');
      expect(a.width + 10 + b.width, closeTo(header.width, 1));
      expect(c.top, greaterThan(a.bottom), reason: 'üçüncü kart alt satırda');
      expect(c.width, closeTo(header.width, 0.5), reason: 'tek kalan son kart tam genişlikte');
    });

    testWidgets('yazı ölçeği 1.5x: satırdaki sayaç kartları yine eşit yükseklikte ve rozet metni kesilmez', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'service_user', size: const Size(360, 1600), textScale: 1.5);
      await flush(tester);
      final a = cardRect(tester, 'card_metric_devices');
      final b = cardRect(tester, 'card_metric_commissioned');
      expect(a.top, closeTo(b.top, 0.5));
      expect(a.height, closeTo(b.height, 0.5));
      // 'ABONE DAİRE' 1.5x'te 'ABONE DAİ…' diye kesiliyordu: ortak GlassPill rozeti satıra SARILIR (tek satır + üç nokta
      // değil). Gerçek yazı tipiyle görünüm `test/visual/consoles/service_console_phone_*_1.5.png`'dedir (Ahem'de
      // her harf 1 em olduğundan sarma sayısı ölçülmez; sarma KİPİ doğrulanır).
      for (final badge in ['ABONE DAİRE', 'STOK & PANO']) {
        final text = tester.widget<Text>(find.text(badge));
        expect(text.softWrap, isTrue, reason: badge);
        expect(text.maxLines, greaterThan(1), reason: badge);
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('çok büyük yazıda (2.0x) sayaçlar TEK sütunda yatay kartlar (iki dar sütunda sözcükler kırılıyordu)',
        (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'super_user', size: const Size(320, 2400), textScale: 2.0);
      await flush(tester);
      final header = cardRect(tester, 'card_console_header');
      final rects = [
        for (final k in ['card_metric_service_managers', 'card_metric_devices', 'card_metric_commissioned'])
          cardRect(tester, k),
      ];
      for (final r in rects) {
        expect(r.left, closeTo(header.left, 0.5));
        expect(r.width, closeTo(header.width, 0.5), reason: 'tek sütun: tam genişlik');
      }
      expect(rects[1].top, greaterThan(rects[0].bottom));
      expect(rects[2].top, greaterThan(rects[1].bottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('tablette (800 dp): 3 sayaç tek satırda eşit yükseklikte; eylemler 2 sütunda satır başına eşit yükseklik',
        (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(800, 1400));
      await flush(tester);
      final m = [
        for (final k in ['card_metric_service_managers', 'card_metric_devices', 'card_metric_commissioned'])
          cardRect(tester, k),
      ];
      expect(m[0].top, closeTo(m[1].top, 0.5));
      expect(m[1].top, closeTo(m[2].top, 0.5));
      expect(m[0].height, closeTo(m[1].height, 0.5));
      expect(m[1].height, closeTo(m[2].height, 0.5));

      final a1 = cardRect(tester, 'card_action_inventory');
      final a2 = cardRect(tester, 'card_action_service_managers');
      final a3 = cardRect(tester, 'card_action_subscribers');
      final a4 = cardRect(tester, 'card_action_doctor');
      expect(a1.top, closeTo(a2.top, 0.5));
      expect(a1.height, closeTo(a2.height, 0.5), reason: 'önceden alt kenarlar 4-5 dp hizasızdı');
      expect(a3.top, closeTo(a4.top, 0.5));
      expect(a3.height, closeTo(a4.height, 0.5));
    });

    testWidgets('servis konsolu tabletinde 5 eylem: çift satırlar eşit yükseklikte, TEK kalan son kart tam genişlikte',
        (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'service_user', size: const Size(800, 1600));
      await flush(tester);
      final header = cardRect(tester, 'card_console_header');
      final last = cardRect(tester, 'card_action_emergency_reset');
      final first = cardRect(tester, 'card_action_commissioning');
      expect(last.width, closeTo(header.width, 0.5), reason: 'yetim hücre yok: son kart tam genişlikte');
      expect(last.top, greaterThan(first.bottom));
      expect(
        cardRect(tester, 'card_action_replace_board').height,
        closeTo(cardRect(tester, 'card_action_wifi_recovery').height, 0.5),
      );
    });

    testWidgets('masaüstünde (1400 dp) içerik 960 dp ile sınırlı ve ortalı (kartlar çubuğa gerilmez)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(1400, 1200));
      await flush(tester);
      final header = cardRect(tester, 'card_console_header');
      expect(header.width, closeTo(960, 0.5));
      expect(header.center.dx, closeTo(700, 0.5));
    });

    testWidgets('hata kartı: dar genişlikte "Yeniden dene" iletinin ALTINDA, ileti tam genişlikte okunur', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner',
          globalRole: 'super_user',
          size: const Size(360, 1200),
          configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);
      final message = rectOf(tester, find.text(kServerError.message));
      final retry = rectOf(tester, byKeyName('btn_retry'));
      expect(retry.top, greaterThanOrEqualTo(message.bottom), reason: 'düğme iletinin altında');
      expect(message.width, greaterThan(180), reason: 'ileti ≈ 88 dp\'lik dar sütuna sıkışmaz');
      expect(retry.height, greaterThanOrEqualTo(48));
    });

    testWidgets('hata kartı: büyük yazıda (1.5x) geniş ekranda bile dikey düzen', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner',
          globalRole: 'super_user',
          size: const Size(800, 1400),
          textScale: 1.5,
          configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);
      expect(
        rectOf(tester, byKeyName('btn_retry')).top,
        greaterThanOrEqualTo(rectOf(tester, find.text(kServerError.message)).bottom),
        reason: 'büyük yazıda dikey',
      );
    });

    testWidgets('hata kartı: normal yazıda geniş ekranda ileti ve düğme yan yana', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner',
          globalRole: 'super_user',
          size: const Size(800, 1400),
          configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);
      expect(
        rectOf(tester, byKeyName('btn_retry')).left,
        greaterThanOrEqualTo(rectOf(tester, find.text(kServerError.message)).right),
        reason: 'normal yazıda yan yana',
      );
    });

    testWidgets('hata kartı rose (hata) ve sayaçlar "—" iken orb soluk (devre dışı), uydurma sayı yok', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'super_user', configure: (h) => h.e1.summaryError = kServerError);
      await flush(tester);
      final card = tester.widget<SurfaceCard>(byKeyName('banner_counters_error'));
      expect(card.accent, AppFamilies.rose.base);
      final orbs = find.descendant(of: byKeyName('card_metric_devices'), matching: find.byType(OrbIconBadge));
      expect(tester.widget<OrbIconBadge>(orbs).enabled, isFalse, reason: 'veri yok: orb soluk');
    });

    testWidgets('yükleme iskeleti gerçek sayı satırıyla AYNI yükseklikte: veri gelince kart zıplamaz (1.5x)', (tester) async {
      final gate = Completer<void>();
      await pumpReady(tester, const DashboardPage(),
          role: 'owner',
          globalRole: 'super_user',
          size: const Size(360, 1400),
          textScale: 1.5,
          configure: (h) => h.e1.summaryGate = gate);
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await flush(tester);
      final loading = cardRect(tester, 'card_metric_service_managers').height;
      expect(
        find.descendant(of: byKeyName('card_metric_service_managers'), matching: find.byType(Skeleton)),
        findsOneWidget,
      );

      gate.complete();
      await flush(tester);
      final loaded = cardRect(tester, 'card_metric_service_managers').height;
      expect(loaded, closeTo(loading, 0.5), reason: 'sabit 28 dp iskelet 1.5x\'te kartı ~17 dp uzatıyordu');
    });

    testWidgets('tek vurgulu kart: yalnız başlık kartı aktif; sayaç ve eylem kartlarının kenarı nötr (rim)', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user');
      await flush(tester);
      expect(tester.widget<SurfaceCard>(byKeyName('card_console_header')).active, isTrue);
      for (final key in [
        'card_metric_service_managers',
        'card_metric_devices',
        'card_metric_commissioned',
        'card_action_inventory',
        'card_action_service_managers',
        'card_action_subscribers',
        'card_action_doctor',
      ]) {
        final card = tester.widget<SurfaceCard>(byKeyName(key));
        expect(card.accent, isNull, reason: '$key kategori rengi yalnız orb + rozette');
        expect(card.active, isFalse, reason: key);
      }
    });

    testWidgets('servis konsolu: güvenlik uyarısı amber kenarlı ama parıltılı (aktif) DEĞİL', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'service_user');
      await flush(tester);
      final card = tester.widget<SurfaceCard>(byKeyName('notice_service_safety'));
      expect(card.accent, AppFamilies.amber.base);
      expect(card.active, isFalse);
    });

    testWidgets('menü ipucu: "☰" Unicode glifi YOK (boş kutu çiziyordu); satır içi menü simgesi + anlam etiketi',
        (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(360, 1200));
      await flush(tester);
      expect(find.textContaining('☰'), findsNothing);
      expect(
        find.descendant(of: byKeyName('tip_drawer'), matching: find.byIcon(Icons.menu_rounded)),
        findsOneWidget,
      );
      final tip = tester.widget<Text>(
        find.descendant(
          of: byKeyName('tip_drawer'),
          matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
        ),
      );
      expect(tip.semanticsLabel, contains('menü düğmesinden'));
    });

    testWidgets('menü ipucu: geniş kartta tek satır (düğme dikeyde ortalı), dar kartta düğme alt satırda', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(800, 1400));
      await flush(tester);
      final card = cardRect(tester, 'tip_drawer');
      final button = rectOf(tester, byKeyName('btn_open_drawer'));
      expect(button.center.dy, closeTo(card.center.dy, 2), reason: 'tek satır: düğme dikeyde ortalı');

      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(360, 1400));
      await flush(tester);
      final narrowCard = cardRect(tester, 'tip_drawer');
      final narrowButton = rectOf(tester, byKeyName('btn_open_drawer'));
      expect(narrowButton.bottom, greaterThan(narrowCard.center.dy), reason: 'dar kartta düğme alt satırda');
    });

    // BİLİNÇLİ güncelleme (2. tur bulgusu r2_consoles: bölüm başlığı dili): konsol bölüm başlıkları pano başlıklarıyla AYNI
    // SectionHeader (solda 32 dp mini orb + 10 dp boşluk); başlık metni orb'un sağında (16 + 32 + 10 = 58 dp) başlar ve
    // dar ekranda bağlantı başlık METNİYLE sol kenarda hizalanır (eskiden orb'suz çıplak metin: ikisi de 16 dp'deydi).
    testWidgets('bölüm başlığı: dar ekranda bağlantı alta iner ve başlık metniyle sol kenarda hizalanır', (tester) async {
      await pumpReady(tester, const DashboardPage(),
          role: 'owner', globalRole: 'super_user', size: const Size(360, 1400), textScale: 1.5);
      await flush(tester);
      final title = rectOf(tester, find.text('Hızlı Yönetici İşlemleri'));
      final link = rectOf(tester, byKeyName('btn_open_service_management'));
      expect(link.top, greaterThanOrEqualTo(title.bottom), reason: 'bağlantı başlığın altında');
      expect(title.left, closeTo(16 + 32 + 10, 0.5), reason: 'başlık metni mini orb\'un (16 dp + 32 dp + 10 dp boşluk) sağında');
      expect(link.left, closeTo(title.left, 0.5), reason: 'bağlantı başlık metniyle aynı sol kenarda (TextButton iç dolgusu yok)');
      expect(link.height, greaterThanOrEqualTo(48));
    });

    testWidgets('bölüm başlığı iki konsolda pano başlığıyla AYNI bileşen: SectionHeader (mini orb + 15/800), rozet/sayaç yok',
        (tester) async {
      for (final role in ['super_user', 'service_user']) {
        await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: role, size: const Size(800, 1400));
        await flush(tester);
        final text = role == 'super_user' ? 'Hızlı Yönetici İşlemleri' : 'Saha Servis & Devreye Alma Görevleri';
        final header = find.ancestor(of: find.text(text), matching: find.byType(SectionHeader));
        expect(header, findsOneWidget, reason: role);
        final style = tester.widget<Text>(find.text(text)).style!;
        expect(style.fontSize, AppText.cardTitle, reason: role);
        expect(style.fontWeight, FontWeight.w800, reason: role);
        expect(tester.widget<SectionHeader>(header).badge, isNull, reason: '$role: sayaç rozeti yok');
      }
    });

    testWidgets('bölüm başlığı: geniş ekranda bağlantı aynı satırda ve sağ kenara yaslı', (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'super_user', size: const Size(800, 1400));
      await flush(tester);
      final title = rectOf(tester, find.text('Hızlı Yönetici İşlemleri'));
      final link = rectOf(tester, byKeyName('btn_open_service_management'));
      expect(link.center.dy, closeTo(title.center.dy, 2), reason: 'aynı satırda');
      expect(link.right, closeTo(800 - 16, 0.5), reason: 'sağ kenara yaslı');
    });

    testWidgets('servis konsolunda bölüm başlığı ile ilk kart arası >= 14 dp; orb 16 dp oluğuna, metin orb\'un sağına oturur',
        (tester) async {
      await pumpReady(tester, const DashboardPage(), role: 'owner', globalRole: 'service_user', size: const Size(800, 1400));
      await flush(tester);
      final service = rectOf(tester, find.text('Saha Servis & Devreye Alma Görevleri'));
      final firstCard = cardRect(tester, 'card_action_commissioning');
      expect(firstCard.top - service.bottom, greaterThanOrEqualTo(14));
      expect(firstCard.left, closeTo(16, 0.5));
      expect(service.left, closeTo(16 + 32 + 10, 0.5), reason: 'başlık metni mini orb\'un sağında');
    });
  });

  group('Pano üst çubuğu: avatar baş harfi', () {
    testWidgets('adı boş kullanıcıda varsayılan harf; emoji ile başlayan ad bozulmaz', (tester) async {
      final h = await pumpReady(tester, const DashboardPage(), role: 'owner');
      h.state.setCurrentUserForTesting(const UserModel(id: 'u1', email: 'x@y.z', fullName: '', role: 'user'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('nav_profile'), matching: find.text('U')), findsOneWidget);

      h.state.setCurrentUserForTesting(const UserModel(id: 'u1', email: 'x@y.z', fullName: '😀 Ahmet', role: 'user'));
      await flush(tester);
      expect(find.descendant(of: byKeyName('nav_profile'), matching: find.text('😀')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
