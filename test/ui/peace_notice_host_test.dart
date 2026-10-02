import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/services/peace_notice_controller.dart';
import 'package:ev_otomasyon/services/push/push_coordinator.dart';
import 'package:ev_otomasyon/ui/theme/app_theme.dart';
import 'package:ev_otomasyon/ui/widgets/peace_notice_host.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../support/support.dart' show kHomeB, testHome;
import 'peace_ui_rig.dart';

/// `PeaceNoticeHost`: afiş ve yumuşak izin istemi MaterialBanner, "Hepsini kapat" sonucu SnackBar olarak
/// ScaffoldMessenger üzerinden gösterilir (gerçek denetleyici + sahte push; gerçek Scaffold rotaları).

const _banner = Key('banner_peace_notice');
const _title = Key('text_peace_notice_title');
const _body = Key('text_peace_notice_body');
const _closeAll = Key('btn_peace_notice_close_all');
const _dismiss = Key('btn_peace_notice_dismiss');
const _softBanner = Key('banner_peace_soft_prompt');
const _softAccept = Key('btn_peace_soft_prompt_accept');
const _softLater = Key('btn_peace_soft_prompt_later');
const _snack = Key('snack_peace_close_result');
const _pageButton = Key('page_button');
const _pageLeading = Key('page_leading');

const _skippedResult = <String, dynamic>{
  'closed_count': 1,
  'skipped_count': 1,
  'resolved': false,
  'nothing_to_do': false,
  'message': 'Bir lamba güvenle kapatılamadı; lütfen elle kontrol edin.',
};

/// Kısmi sonuçta (`skipped_count > 0`) denetleyicinin ürettiği KISA ileti (sunucu iletisi kullanılmaz).
const _skippedMessage =
    'Komut gönderildi; 1 öğe uzaktan kapatılamadı, lütfen elle kontrol edin.';

/// Sunucunun GERÇEK "kısmen kapatılamadı" iletisi (`buildCloseMessage`, 166 karakter; kritik talimat SONDA).
/// Kısmi sonuçta artık gösterilmez (denetleyici kısa ileti üretir: [_skippedMessage]); uzun bir ileti hâlâ
/// hata yolundan ([ApiException]) gelebildiğinden SnackBar yerleşim dayanıklılığı bununla ölçülür.
const _realServerMessage =
    'Huzur modu: 2 lamba, 1 panjur için kapatma komutu cihaza iletildi. 1 lamba birden fazla panonun '
    'ortak bağlantısı nedeniyle uzaktan kapatılamadı; lütfen elle kontrol edin.';

const _realSkippedResult = <String, dynamic>{
  'closed_count': 2,
  'closed_shutters': 1,
  'skipped_count': 1,
  'resolved': false,
  'nothing_to_do': false,
  'message': _realServerMessage,
};

/// Sonuç SnackBar'ının kapatma düğmesi (eylem yok: `showCloseIcon`; simge `Icons.close`).
final _snackClose = find.descendant(
  of: find.byKey(_snack),
  matching: find.byType(IconButton),
);

Future<PeaceUiRig> _pumpRig(
  WidgetTester tester, {
  String role = 'owner',
  PushState startState = PushState.registered,
  bool softPromptAlreadyShown = false,
  ThemeMode themeMode = ThemeMode.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  Size size = const Size(360, 740),
  Widget? page,
  ThemeData Function(ThemeData base)? decorateTheme,
}) async {
  usePhone(tester, size: size);
  final rig = PeaceUiRig.create(
    role: role,
    startState: startState,
    softPromptAlreadyShown: softPromptAlreadyShown,
  );
  addTearDown(rig.dispose);
  await tester.pumpWidget(
    peaceApp(
      rig: rig,
      themeMode: themeMode,
      textScale: textScale,
      disableAnimations: disableAnimations,
      page: page,
      decorateTheme: decorateTheme,
    ),
  );
  await tester.pump(); // push.start mikro görevleri
  return rig;
}

/// Olay -> denetleyici bildirimi -> köprü mikro görevi -> banner kurulumu -> animasyon.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

Future<void> _showNotice(
  WidgetTester tester,
  PeaceUiRig rig, {
  String? body,
  int id = 41,
}) async {
  rig.push.emitNotice(
    rig.notice(id: id, body: body ?? 'Salonda 2 lamba, 1 panjur açık.'),
  );
  await _settle(tester);
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Odaktaki düğmenin anahtarı (FilledButton/TextButton/IconButton/ElevatedButton).
String _focusedKey() {
  final ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return 'null';
  for (final probe in <Widget? Function()>[
    () => ctx.findAncestorWidgetOfExactType<FilledButton>(),
    () => ctx.findAncestorWidgetOfExactType<TextButton>(),
    () => ctx.findAncestorWidgetOfExactType<IconButton>(),
    () => ctx.findAncestorWidgetOfExactType<ElevatedButton>(),
  ]) {
    final w = probe();
    if (w != null) return '${(w.key as ValueKey<String>?)?.value ?? w.key}';
  }
  return 'other:${ctx.widget.runtimeType}';
}

String _keyName(Key key) => (key as ValueKey<String>).value;

// -----------------------------------------------------------------------------
// Gerçek yazı tipi (Roboto): SDK önbelleğinden; yoksa gerçek-yazı tipi testleri atlanır.
// -----------------------------------------------------------------------------

Directory? _materialFontsDir() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (dir.existsSync()) return dir;
  }
  var d = File(Platform.resolvedExecutable).parent;
  for (var i = 0; i < 8; i++) {
    final dir = Directory('${d.path}/material_fonts');
    if (dir.existsSync()) return dir;
    d = d.parent;
  }
  return null;
}

Future<void> _loadRoboto(Directory dir) async {
  final loader = FontLoader('Roboto');
  for (final f in <String>['regular', 'medium', 'bold']) {
    final bytes = await File('${dir.path}/roboto-$f.ttf').readAsBytes();
    loader.addFont(Future<ByteData>.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
}

ThemeData _withRoboto(ThemeData t) => t.copyWith(
  textTheme: t.textTheme.apply(fontFamily: 'Roboto'),
  primaryTextTheme: t.primaryTextTheme.apply(fontFamily: 'Roboto'),
);

const _longBody =
    'Salonda 2 lamba, mutfakta 1 lamba, yatak odasında 3 lamba, çocuk odasında 1 lamba, koridorda 2 lamba ve '
    'iki panjur açık. Gece yarısına kadar kimse evde değilse güvenlik için hepsini kapatmanız önerilir. '
    'Bu özet cihazların son bilinen durumuna göre hazırlandı; ayrıntıları ayar kartından görebilirsiniz.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fontsDir = _materialFontsDir();

  group('bildirim yokken', () {
    testWidgets('banner/snackbar yok; çocuk (sayfa) aynen çizilir', (
      tester,
    ) async {
      await _pumpRig(tester);
      await _settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(_pageButton), findsOneWidget);
    });

    testWidgets(
      'köprü kendi bir şey çizmez: Stack/Positioned/Material yok (çocuk aynen döner)',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        final host = find.byType(PeaceNoticeHost);
        expect(host, findsOneWidget);
        // Köprünün hemen altındaki ilk öğe çocuğun kendisidir (örtü yok).
        expect(
          find.descendant(of: host, matching: find.byType(Positioned)),
          findsNothing,
          reason: 'Stack/Positioned örtüsü kullanılmaz',
        );
        expect(tester.widget<PeaceNoticeHost>(host).child, isA<Widget>());
      },
    );
  });

  group('bildirim afişi (MaterialBanner)', () {
    testWidgets('başlık, gövde ve iki eylem görünür', (tester) async {
      final rig = await _pumpRig(tester);
      await _showNotice(tester, rig);

      expect(find.byKey(_banner), findsOneWidget);
      expect(find.text('Ev A'), findsOneWidget);
      expect(find.text('Salonda 2 lamba, 1 panjur açık.'), findsOneWidget);
      expect(find.byKey(_closeAll), findsOneWidget);
      expect(find.byKey(_dismiss), findsOneWidget);
      expect(find.text('Hepsini kapat'), findsOneWidget);
      expect(find.text('Kapat'), findsOneWidget);
    });

    testWidgets('başlık/gövde yoksa varsayılan Türkçe metinler', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      rig.push.emitNotice(rig.notice(title: null, body: null));
      await _settle(tester);
      expect(find.text('Gece hatırlatması'), findsOneWidget);
      expect(find.text('Açık lamba ve panjur var.'), findsOneWidget);
    });

    testWidgets(
      'sayfa içeriğini AŞAĞI iter: banner AppBar\'ın altında, gövde banner\'ın altında',
      (tester) async {
        final rig = await _pumpRig(tester);
        final before = tester.getRect(find.byKey(_pageButton));
        await _showNotice(tester, rig);

        final banner = tester.getRect(find.byKey(_banner));
        final appBarBottom = tester.getRect(find.byType(AppBar)).bottom;
        final after = tester.getRect(find.byKey(_pageButton));
        expect(banner.top, greaterThanOrEqualTo(appBarBottom - 0.5));
        expect(banner.left, 0);
        expect(banner.right, 360);
        expect(
          after.top,
          greaterThanOrEqualTo(banner.bottom - 0.5),
          reason: 'gövde banner\'ın altında',
        );
        expect(after.center.dy, greaterThan(before.center.dy - 0.5));
      },
    );

    testWidgets(
      'hit-test: banner varken AppBar geri düğmesine ve gövde düğmesine dokunuş ÇALIŞIR',
      (tester) async {
        final rig = await _pumpRig(tester);
        await tester.tap(find.byKey(_pageLeading));
        await tester.pump();
        expect(
          find.text('Demo sayfa 1'),
          findsOneWidget,
          reason: 'afiş yokken',
        );

        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_pageLeading));
        await tester.pump();
        expect(
          find.text('Demo sayfa 2'),
          findsOneWidget,
          reason: 'afiş varken AppBar eylemi yutulmamalı',
        );

        await tester.tap(find.byKey(_pageButton));
        await tester.pump();
        expect(find.text('Sayfa düğmesi 1'), findsOneWidget);
        expect(find.byKey(_banner), findsOneWidget);
      },
    );

    testWidgets(
      'hit-test (yatay 640x360): AppBar düğmesi çalışır, banner ekranın yarısını aşmaz',
      (tester) async {
        final rig = await _pumpRig(tester, size: const Size(640, 360));
        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_pageLeading));
        await tester.pump();
        expect(find.text('Demo sayfa 1'), findsOneWidget);
        final banner = tester.getRect(find.byKey(_banner));
        expect(banner.height, lessThan(360 * 0.5));
      },
    );

    testWidgets('"Kapat": banner kalkar, aynı bildirim bir daha gösterilmez', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      await _showNotice(tester, rig);

      await tester.tap(find.byKey(_dismiss));
      await _settle(tester);
      expect(find.byKey(_banner), findsNothing);
      expect(rig.controller.pending, isNull);

      rig.push.emitNotice(rig.notice());
      await _settle(tester);
      expect(find.byKey(_banner), findsNothing);
    });

    testWidgets(
      '"Hepsini kapat": istek bildirim kimliğiyle gider, banner kalkar, sonuç SnackBar olur',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);

        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);

        expect(rig.cloud.closeCalls, hasLength(1));
        expect(rig.cloud.closeCalls.single.noticeId, 41);
        expect(find.byKey(_banner), findsNothing);
        expect(find.byKey(_snack), findsOneWidget);
        expect(find.text('Kapatma komutu gönderildi.'), findsOneWidget);
        expect(
          rig.controller.closeMessage,
          isNull,
          reason: 'ileti gösterilince denetleyiciden tüketilir',
        );
      },
    );

    testWidgets(
      'bazı lambalar kapatılamadı: banner açık kalır, uyarı SnackBar olarak gösterilir ve tüketilir',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.cloud.closeResult = _skippedResult;
        await _showNotice(tester, rig);

        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);

        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_snack), findsOneWidget);
        expect(find.text(_skippedMessage), findsOneWidget);
        expect(
          find.text(
            'Bir lamba güvenle kapatılamadı; lütfen elle kontrol edin.',
          ),
          findsNothing,
          reason: 'sunucu iletisi kullanılmaz',
        );
        expect(rig.controller.closeMessage, isNull);
      },
    );

    testWidgets(
      'hata: Türkçe hata iletisi SnackBar olur; iç hata ayrıntısı sızmaz',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.cloud.closeError = StateError('iç hata ayrıntısı');
        await _showNotice(tester, rig);

        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);

        expect(
          find.text('Lambalar kapatılamadı. Lütfen tekrar deneyin.'),
          findsOneWidget,
        );
        expect(find.textContaining('iç hata'), findsNothing);
        expect(find.byKey(_banner), findsOneWidget);
      },
    );

    testWidgets(
      'iş bitti (afiş kalktı): bilgi iletisi 8 sn sonra kendiliğinden kapanır; kapatma simgesi var, "Tamam" eylemi yok',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        expect(find.byKey(_snack), findsOneWidget);
        expect(_snackClose, findsOneWidget);
        expect(find.text('Tamam'), findsNothing);

        await tester.pump(const Duration(seconds: 6));
        expect(find.byKey(_snack), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(find.byKey(_snack), findsNothing);
      },
    );

    testWidgets(
      'afiş açık kaldıysa (uyarı/hata) ileti de KALICI DEĞİL: 8 sn sonra kapanır, afiş açık kalır; kapatma simgesiyle erken kapanır',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.cloud.closeResult = _skippedResult;
        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        expect(find.byKey(_snack), findsOneWidget);
        expect(find.text('Tamam'), findsNothing, reason: 'eylem yok');
        expect(_snackClose, findsOneWidget);

        await tester.pump(const Duration(seconds: 6));
        expect(find.byKey(_snack), findsOneWidget);
        await tester.pump(const Duration(seconds: 3));
        await tester.pumpAndSettle();
        expect(
          find.byKey(_snack),
          findsNothing,
          reason: 'uyarı da süre sonunda kalkar (kuyruğu bekletmez)',
        );
        expect(find.byKey(_banner), findsOneWidget, reason: 'afiş açık kalır');

        // Yeni sonuç: kapatma simgesi ile erken kapanır.
        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        expect(find.byKey(_snack), findsOneWidget);
        await tester.tap(_snackClose);
        await _settle(tester);
        expect(find.byKey(_snack), findsNothing);
        expect(find.byKey(_banner), findsOneWidget, reason: 'afiş açık kalır');
      },
    );

    testWidgets(
      'aynı ileti ikinci kez gelince (tekrar dene) yine gösterilir: ileti her seferinde tüketilir',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.cloud.closeResult = _skippedResult;
        await _showNotice(tester, rig);

        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        await tester.tap(_snackClose);
        await _settle(tester);
        expect(find.byKey(_snack), findsNothing);

        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        expect(rig.cloud.closeCalls, hasLength(2));
        expect(
          find.byKey(_snack),
          findsOneWidget,
          reason: 'aynı metin olsa da yeni sonuç yeniden gösterilir',
        );
        expect(rig.controller.closeMessage, isNull);
      },
    );

    testWidgets(
      'mevcut bir SnackBar (örn. komut hatası) gizlenir, sonuç iletisi onun yerine geçer',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .showSnackBar(
              const SnackBar(
                content: Text('Başka bir ileti'),
                duration: Duration(seconds: 30),
              ),
            );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Başka bir ileti'), findsOneWidget);

        await tester.tap(find.byKey(_closeAll));
        await tester.pump();
        await tester.pump();
        // Eski SnackBar çıkış animasyonunu bitirince sonuç iletisi görünür (30 sn beklemeden).
        await tester.pump(const Duration(seconds: 1));
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Başka bir ileti'), findsNothing);
        expect(find.byKey(_snack), findsOneWidget);
      },
    );

    testWidgets(
      'yetki yokken (aktif ev misafirlik) "Hepsini kapat" gizli, "Kapat" kalır; banner yeniden gösterilmez',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        expect(find.byKey(_closeAll), findsOneWidget);
        final before = tester.widget<MaterialBanner>(find.byKey(_banner));

        rig.activateGuestHome();
        await _settle(tester);

        expect(rig.state.capabilities.canUseGroupCommands, isFalse);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_closeAll), findsNothing);
        expect(find.byKey(_dismiss), findsOneWidget);
        expect(
          identical(tester.widget<MaterialBanner>(find.byKey(_banner)), before),
          isTrue,
        );
      },
    );
  });

  group('reaktif içerik (yeniden gösterme/titreşim yok)', () {
    testWidgets(
      'closing: düğme devre dışı + ilerleme göstergesi; banner AYNI örnek kalır; bitince kalkar',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        final before = tester.widget<MaterialBanner>(find.byKey(_banner));
        final rectBefore = tester.getRect(find.byKey(_banner));
        rig.cloud.closeGate = Completer<void>();

        await tester.tap(find.byKey(_closeAll));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(rig.controller.closing, isTrue);
        expect(find.text('Kapatılıyor…'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(
          tester.widget<FilledButton>(find.byKey(_closeAll)).onPressed,
          isNull,
        );
        expect(
          identical(tester.widget<MaterialBanner>(find.byKey(_banner)), before),
          isTrue,
          reason: 'banner yeniden gösterilmedi',
        );
        expect(
          tester.getRect(find.byKey(_banner)).top,
          rectBefore.top,
          reason: 'titreşim/kayma yok',
        );

        // Çift dokunuş ikinci istek üretmez.
        await tester.tap(find.byKey(_closeAll), warnIfMissed: false);
        await tester.pump();
        expect(rig.cloud.closeCalls, hasLength(1));

        rig.cloud.closeGate!.complete();
        await _settle(tester);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byKey(_banner), findsNothing);
      },
    );

    testWidgets(
      'closing + "hareketi azalt": dönen gösterge yok, pumpAndSettle zaman aşımına girmez',
      (tester) async {
        final rig = await _pumpRig(tester, disableAnimations: true);
        await _showNotice(tester, rig);
        rig.cloud.closeGate = Completer<void>();

        await tester.tap(find.byKey(_closeAll));
        await tester.pumpAndSettle();

        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.byIcon(Icons.hourglass_empty), findsOneWidget);
        expect(find.text('Kapatılıyor…'), findsOneWidget);

        rig.cloud.closeGate!.complete();
        await _settle(tester);
      },
    );

    testWidgets(
      'aynı bildirimin güncellenmiş içeriği banner\'ı yenilemeden metni günceller',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig, body: 'Salonda 2 lamba açık.');
        final before = tester.widget<MaterialBanner>(find.byKey(_banner));

        await _showNotice(tester, rig, body: 'Salonda 1 lamba açık.');
        expect(find.text('Salonda 1 lamba açık.'), findsOneWidget);
        expect(find.text('Salonda 2 lamba açık.'), findsNothing);
        expect(
          identical(tester.widget<MaterialBanner>(find.byKey(_banner)), before),
          isTrue,
        );
      },
    );

    testWidgets(
      'başka bir bildirim gelince (farklı dedupeKey) banner yenilenir: tek banner, yeni metin',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig, body: 'Birinci bildirim.');
        final first = tester.widget<MaterialBanner>(find.byKey(_banner));
        await _showNotice(tester, rig, body: 'İkinci bildirim.', id: 42);

        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(find.text('İkinci bildirim.'), findsOneWidget);
        expect(find.text('Birinci bildirim.'), findsNothing);
        expect(
          identical(tester.widget<MaterialBanner>(find.byKey(_banner)), first),
          isFalse,
          reason: 'farklı bildirim: banner yeniden gösterilir (imza tür + dedupeKey)',
        );
      },
    );

    testWidgets(
      'hızlı ardışık değişimler: istisna yok, kalıntı yok, son durum doğru',
      (tester) async {
        final rig = await _pumpRig(tester);
        for (var i = 0; i < 6; i++) {
          rig.push.emitNotice(rig.notice(id: 100 + i, body: 'Bildirim $i'));
          await tester.pump();
          if (i.isEven) rig.controller.dismiss();
          await tester.pump(const Duration(milliseconds: 30));
        }
        await _settle(tester);
        expect(tester.takeException(), isNull);
        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(find.text('Bildirim 5'), findsOneWidget);

        rig.controller.dismiss();
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('afiş gelip gidince sayfa (çocuk) yeniden kurulmaz', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      await tester.pumpAndSettle();
      final before = DemoPage.builds;
      await _showNotice(tester, rig);
      rig.controller.dismiss();
      await _settle(tester);
      // Banner kapsamını messenger yönetir; DemoPage'in kendi State'i yeniden kurulabilir ama köprü çocuğu
      // yeniden yaratmaz: en çok birkaç yerleşim yenilemesi (banner girişinde Scaffold'un kurulumu).
      expect(DemoPage.builds - before, lessThanOrEqualTo(6));
    });
  });

  group('öncelik ve yumuşak izin istemi', () {
    testWidgets('bildirim afişi > yumuşak istem; afiş kalkınca istem görünür', (
      tester,
    ) async {
      final rig = await _pumpRig(tester, startState: PushState.needsPermission);
      await _settle(tester);
      expect(find.byKey(_softBanner), findsOneWidget);

      await _showNotice(tester, rig);
      expect(find.byKey(_banner), findsOneWidget);
      expect(find.byKey(_softBanner), findsNothing);
      expect(find.byType(MaterialBanner), findsOneWidget);

      await tester.tap(find.byKey(_dismiss));
      await _settle(tester);
      expect(find.byKey(_banner), findsNothing);
      expect(find.byKey(_softBanner), findsOneWidget);
    });

    testWidgets(
      'izin yok + ilk kez: istem görünür; "Bildirimleri aç" izin ister ve istem kalkar',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          startState: PushState.needsPermission,
        );
        await _settle(tester);
        expect(find.byKey(_softBanner), findsOneWidget);
        expect(
          find.text(
            'Açık kalan lambalar için gece bildirimi almak ister misiniz?',
          ),
          findsOneWidget,
        );
        expect(
          rig.push.calls,
          isNot(contains('request')),
          reason: 'sistem penceresi kendiliğinden açılmaz',
        );

        await tester.tap(find.byKey(_softAccept));
        await _settle(tester);
        expect(rig.push.calls, contains('request'));
        expect(rig.store.prompted, isTrue);
        expect(find.byType(MaterialBanner), findsNothing);
      },
    );

    testWidgets('"Şimdi değil": istem kalkar ve bir daha sorulmaz', (
      tester,
    ) async {
      final rig = await _pumpRig(tester, startState: PushState.needsPermission);
      await _settle(tester);
      await tester.tap(find.byKey(_softLater));
      await _settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(rig.push.calls, isNot(contains('request')));
      expect(rig.store.prompted, isTrue);
    });

    testWidgets('daha önce sorulduysa istem hiç çıkmaz', (tester) async {
      await _pumpRig(
        tester,
        startState: PushState.needsPermission,
        softPromptAlreadyShown: true,
      );
      await _settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);
    });
  });

  group('oturum ve ömür döngüsü', () {
    testWidgets('oturum bitince banner kalkar (uygunluk kaybı)', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      await _showNotice(tester, rig);
      expect(find.byKey(_banner), findsOneWidget);

      rig.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
      await _settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);
      expect(rig.controller.pending, isNull);
    });

    testWidgets(
      'köprü ağaçtan kalkınca banner kaldırılır; sonraki bildirimlerde messenger\'a erişilmez',
      (tester) async {
        final rig = await _pumpRig(tester);
        final showHost = ValueNotifier<bool>(true);
        addTearDown(showHost.dispose);
        await tester.pumpWidget(
          ChangeNotifierProvider<AutomationState>.value(
            value: rig.state,
            child: MaterialApp(
              builder: (context, child) =>
                  ChangeNotifierProvider<PeaceNoticeController>.value(
                    value: rig.controller,
                    child: ValueListenableBuilder<bool>(
                      valueListenable: showHost,
                      builder: (_, show, _) =>
                          show ? PeaceNoticeHost(child: child!) : child!,
                    ),
                  ),
              home: const DemoPage(),
            ),
          ),
        );
        await _showNotice(tester, rig);
        expect(find.byKey(_banner), findsOneWidget);

        showHost.value = false;
        await _settle(tester);
        expect(
          find.byKey(_banner),
          findsNothing,
          reason: 'köprü gidince banner kaldırılır',
        );
        expect(tester.takeException(), isNull);

        // Köprü yokken yeni bildirim: erişim/istisna yok, banner çıkmaz.
        rig.push.emitNotice(rig.notice(id: 77));
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('uygulama tümden kapanırken (banner açık) istisna yok', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      await _showNotice(tester, rig);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(rig.controller.pending, isNotNull);
    });

    testWidgets(
      'Scaffold yokken (açılış ekranı) istisna yok; Scaffold gelince banner görünür',
      (tester) async {
        final rig = await _pumpRig(tester, page: const SizedBox.shrink());
        rig.push.emitNotice(rig.notice());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull);
        expect(find.byType(MaterialBanner), findsNothing);
        expect(rig.controller.pending, isNotNull);

        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const DemoPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(_banner), findsOneWidget);
      },
    );

    testWidgets(
      'Scaffold yokken gelen sonuç iletisi denetleyicide kalır, Scaffold gelince gösterilir ve tüketilir',
      (tester) async {
        final rig = await _pumpRig(tester, page: const SizedBox.shrink());
        rig.cloud.closeResult = _skippedResult;
        rig.push.emitNotice(rig.notice());
        await tester.pump();
        await tester.pump();
        await rig.controller.closeAll();
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          rig.controller.closeMessage,
          isNotNull,
          reason: 'gösterilemedi: tüketilmedi',
        );
        expect(tester.takeException(), isNull);

        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push(
            MaterialPageRoute<void>(builder: (_) => const DemoPage()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(find.byKey(_snack), findsOneWidget);
        expect(rig.controller.closeMessage, isNull);
      },
    );

    testWidgets(
      'ekran okuyucunun "kapat" (dismiss) eylemi afişi kapatır ve bir daha göstermez',
      (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);

        tester.semantics.performAction(
          find.semantics.byAction(SemanticsAction.dismiss),
          SemanticsAction.dismiss,
        );
        await _settle(tester);

        expect(find.byType(MaterialBanner), findsNothing);
        expect(
          rig.controller.pending,
          isNull,
          reason: 'dismiss denetleyiciye bildirilir',
        );
        rig.push.emitNotice(rig.notice());
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
        handle.dispose();
      },
    );

    testWidgets(
      'ekran okuyucunun "kapat" eylemi yumuşak istemi de kapatır (bir daha sorulmaz)',
      (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await _pumpRig(
          tester,
          startState: PushState.needsPermission,
        );
        await _settle(tester);
        tester.semantics.performAction(
          find.semantics.byAction(SemanticsAction.dismiss),
          SemanticsAction.dismiss,
        );
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
        expect(rig.controller.softPromptVisible, isFalse);
        expect(rig.store.prompted, isTrue);
        handle.dispose();
      },
    );

    testWidgets(
      'banner açıkken tema değişince banner yeni temaya göre yenilenir (renkler uyumlu kalır)',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        Color bannerColor() => tester
            .widget<Material>(
              find
                  .descendant(
                    of: find.byKey(_banner),
                    matching: find.byType(Material),
                  )
                  .first,
            )
            .color!;
        expect(bannerColor(), AppTheme.cardLight);

        await tester.pumpWidget(peaceApp(rig: rig, themeMode: ThemeMode.dark));
        await _settle(tester);
        await tester.pumpAndSettle();
        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(bannerColor(), AppTheme.cardDark);
      },
    );
  });

  group('klavye ve erişilebilirlik', () {
    testWidgets(
      'Tab ile "Hepsini kapat" ve "Kapat" düğmelerine odak geçer (rota odak kapsamında)',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);

        final seen = <String>[];
        for (var i = 0; i < 8; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          seen.add(_focusedKey());
        }
        expect(seen, contains(_keyName(_closeAll)));
        expect(seen, contains(_keyName(_dismiss)));
        expect(
          seen,
          contains(_keyName(_pageLeading)),
          reason: 'sayfa düğmeleri de gezintide',
        );

        // Enter ile "Kapat" çalışır.
        for (var i = 0; i < 8 && _focusedKey() != _keyName(_dismiss); i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
        }
        expect(_focusedKey(), _keyName(_dismiss));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
      },
    );

    testWidgets('yumuşak istem düğmelerine de Tab ile ulaşılır', (
      tester,
    ) async {
      await _pumpRig(tester, startState: PushState.needsPermission);
      await _settle(tester);
      final seen = <String>[];
      for (var i = 0; i < 8; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        seen.add(_focusedKey());
      }
      expect(
        seen,
        containsAll(<String>[_keyName(_softAccept), _keyName(_softLater)]),
      );
    });

    testWidgets(
      'Semantics: metin canlı bölge içinde; düğmeler etiketli ve dokunulabilir',
      (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);

        // Başlığın semantik düğümü ya da bir üst düğümü canlı bölgedir (ekran okuyucu afişi kendiliğinden okur).
        SemanticsNode? node = tester.getSemantics(find.byKey(_title));
        var live = false;
        while (node != null) {
          if (node.getSemanticsData().flagsCollection.isLiveRegion) live = true;
          node = node.parent;
        }
        expect(live, isTrue);

        final closeAll = tester
            .getSemantics(find.byKey(_closeAll))
            .getSemanticsData();
        // Ekran okuyucu etiketi ne kapatıldığını söyler ve görünen metni barındırır (WCAG 2.5.3).
        expect(closeAll.label, 'Açık lambaların ve panjurların hepsini kapat');
        expect(closeAll.label.toLowerCase(), contains('hepsini kapat'));
        expect(closeAll.flagsCollection.isButton, isTrue);
        expect(closeAll.hasAction(SemanticsAction.tap), isTrue);
        final dismiss = tester
            .getSemantics(find.byKey(_dismiss))
            .getSemanticsData();
        expect(dismiss.label, 'Bildirimi kapat');
        expect(dismiss.label.toLowerCase(), contains('kapat'));
        expect(dismiss.flagsCollection.isButton, isTrue);
        expect(dismiss.hasAction(SemanticsAction.tap), isTrue);
        // Görünen metin değişmedi.
        expect(find.text('Hepsini kapat'), findsOneWidget);
        expect(find.text('Kapat'), findsOneWidget);
        handle.dispose();
      },
    );

    testWidgets(
      'Semantics: "Hepsini kapat" sürerken ("Kapatılıyor…") ve yumuşak istem düğmeleri etiketli kalır; devre dışı düğme dokunulamaz',
      (tester) async {
        final handle = tester.ensureSemantics();
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        rig.cloud.closeGate = Completer<void>();
        await tester.tap(find.byKey(_closeAll));
        await tester.pump(const Duration(milliseconds: 50));

        final busy = tester
            .getSemantics(find.byKey(_closeAll))
            .getSemanticsData();
        expect(busy.label, contains('Kapatılıyor'));
        expect(busy.flagsCollection.isEnabled, Tristate.isFalse);
        expect(busy.hasAction(SemanticsAction.tap), isFalse);

        rig.cloud.closeGate!.complete();
        await _settle(tester);
        handle.dispose();
      },
    );

    testWidgets('dokunma hedefleri en az 48 dp (afiş ve yumuşak istem)', (
      tester,
    ) async {
      final rig = await _pumpRig(tester, startState: PushState.needsPermission);
      await _settle(tester);
      for (final key in <Key>[_softAccept, _softLater]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$key');
      }
      await _showNotice(tester, rig);
      for (final key in <Key>[_closeAll, _dismiss]) {
        final size = tester.getSize(find.byKey(key));
        expect(size.height, greaterThanOrEqualTo(48), reason: '$key');
        expect(size.width, greaterThanOrEqualTo(48), reason: '$key');
      }
    });

    for (final mode in <ThemeMode>[ThemeMode.light, ThemeMode.dark]) {
      testWidgets(
        '${mode.name}: eylem metinleri ve gövde metni arka planda AA (>= 4.5:1) kontrastlı',
        (tester) async {
          final rig = await _pumpRig(tester, themeMode: mode);
          await _showNotice(tester, rig);
          final bg = AppTheme.getCardColor(tester.element(find.byKey(_banner)));

          final dismissStyle = tester
              .widget<TextButton>(find.byKey(_dismiss))
              .style!;
          final fg = dismissStyle.foregroundColor!.resolve(<WidgetState>{})!;
          expect(
            _contrast(fg, bg),
            greaterThanOrEqualTo(4.5),
            reason: '"Kapat" metni',
          );

          for (final key in <Key>[_closeAll]) {
            final style = tester.widget<FilledButton>(find.byKey(key)).style!;
            expect(
              _contrast(
                style.foregroundColor!.resolve(<WidgetState>{})!,
                style.backgroundColor!.resolve(<WidgetState>{})!,
              ),
              greaterThanOrEqualTo(4.5),
              reason: 'dolgu düğme',
            );
          }

          final body = tester.widget<Text>(find.byKey(_body));
          expect(
            _contrast(body.style!.color!, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'gövde',
          );
          final title = tester.widget<Text>(find.byKey(_title));
          expect(
            _contrast(title.style!.color!, bg),
            greaterThanOrEqualTo(4.5),
            reason: 'başlık',
          );
        },
      );
    }
  });

  group('hareketi azalt', () {
    testWidgets(
      'çıkış anında: bir kare sonra banner ağaçta yok (250 ms animasyon beklenmez)',
      (tester) async {
        final rig = await _pumpRig(tester, disableAnimations: true);
        await _showNotice(tester, rig);
        expect(find.byKey(_banner), findsOneWidget);

        await tester.tap(find.byKey(_dismiss));
        await tester.pump(); // denetleyici bildirimi
        await tester.pump(); // köprü mikro görevi + kare
        expect(find.byKey(_banner), findsNothing);
      },
    );

    testWidgets(
      'normal modda çıkış animasyonlu: ilk karede hâlâ var, animasyon sonunda yok',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_dismiss));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 20));
        expect(find.byKey(_banner), findsOneWidget);
        await tester.pumpAndSettle();
        expect(find.byKey(_banner), findsNothing);
      },
    );
  });

  group('büyük yazı + küçük ekran (gerçek Roboto yazı tipiyle)', () {
    final sizes = <Size>[
      const Size(320, 568),
      const Size(360, 740),
      const Size(640, 360),
    ];
    final scales = <double>[1.0, 1.5, 2.0, 3.0];

    setUpAll(() async {
      if (fontsDir != null) await _loadRoboto(fontsDir);
    });

    testWidgets(
      'gerçek yazı tipi yüklü (Ahem değil): "Yazlık Ev" başlığı kare genişlikte değil',
      (tester) async {
        final rig = await _pumpRig(tester, decorateTheme: _withRoboto);
        rig.push.emitNotice(rig.notice(title: 'Yazlık Ev'));
        await _settle(tester);
        // Ahem'de 9 karakter x 15 dp = 135 dp; Roboto kalın ~70 dp.
        expect(tester.getSize(find.byKey(_title)).width, lessThan(100));
      },
      skip: fontsDir == null,
    );

    testWidgets(
      'eylem metni yazı ölçeğine uyar ama 2.0 ile sınırlıdır (3.0 da banner sayfayı ezmez)',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          size: const Size(360, 740),
          decorateTheme: _withRoboto,
        );
        rig.push.emitNotice(rig.notice(title: 'Yazlık Ev'));
        await _settle(tester);
        double labelHeight() => tester
            .getSize(
              find.descendant(
                of: find.byKey(_dismiss),
                matching: find.byType(Text),
              ),
            )
            .height;
        final h1 = labelHeight();
        final heights = <double, double>{};
        for (final scale in <double>[1.5, 2.0, 3.0]) {
          await tester.pumpWidget(
            peaceApp(rig: rig, textScale: scale, decorateTheme: _withRoboto),
          );
          await _settle(tester);
          heights[scale] = labelHeight();
        }
        expect(
          heights[1.5]! / h1,
          closeTo(1.5, 0.1),
          reason: 'kullanıcının ölçeği uygulanır',
        );
        expect(heights[2.0]! / h1, closeTo(2.0, 0.1));
        expect(
          heights[3.0]! / h1,
          lessThanOrEqualTo(2.1),
          reason: '2.0 üstü sınırlanır',
        );
      },
      skip: fontsDir == null,
    );

    for (final size in sizes) {
      for (final scale in scales) {
        final tag = '${size.width.toInt()}x${size.height.toInt()} ölçek $scale';

        testWidgets(
          'uzun metin, $tag: başlık+gövde en az bir satır görünür, eylemler erişilebilir, taşma yok',
          (tester) async {
            final rig = await _pumpRig(
              tester,
              size: size,
              textScale: scale,
              decorateTheme: _withRoboto,
            );
            rig.push.emitNotice(
              rig.notice(title: 'Yazlık Ev', body: _longBody),
            );
            await _settle(tester);
            expect(
              tester.takeException(),
              isNull,
              reason: 'RenderFlex taşması yok',
            );

            final banner = tester.getRect(find.byKey(_banner));
            expect(
              banner.bottom,
              lessThanOrEqualTo(size.height),
              reason: 'banner ekrana sığar',
            );
            final scroll = find.descendant(
              of: find.byKey(_banner),
              matching: find.byType(SingleChildScrollView),
            );
            final viewport = tester.getRect(scroll);
            expect(
              viewport.height,
              lessThanOrEqualTo(size.height * 0.35 + 0.5),
              reason: 'metin bölgesi ~%35 ile sınırlı',
            );
            for (final key in <Key>[_title, _body]) {
              final r = tester.getRect(find.byKey(key));
              final visible =
                  math.min(r.bottom, viewport.bottom) -
                  math.max(r.top, viewport.top);
              expect(
                visible,
                greaterThanOrEqualTo(18),
                reason: '$key en az bir satır görünür',
              );
            }

            // Eylemler ekranın içinde ve gerçekten dokunulabilir.
            for (final key in <Key>[_closeAll, _dismiss]) {
              final r = tester.getRect(find.byKey(key));
              expect(r.left, greaterThanOrEqualTo(0), reason: '$key');
              expect(r.right, lessThanOrEqualTo(size.width), reason: '$key');
              expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$key');
              expect(r.height, greaterThanOrEqualTo(48), reason: '$key');
            }
            // Metin bölgesi kaydırılabilir: uzun gövde kaybolmaz (sonuna kaydırınca görünür).
            await tester.drag(scroll, const Offset(0, -2000));
            await tester.pump();
            expect(tester.takeException(), isNull);

            await tester.tap(find.byKey(_dismiss));
            await _settle(tester);
            expect(
              find.byType(MaterialBanner),
              findsNothing,
              reason: 'Kapat bu boyutta dokunulabilir',
            );
          },
          skip: fontsDir == null,
        );

        testWidgets(
          'closing + sonuç iletisi, $tag: taşma yok, banner ekrana sığar, SnackBar görünür',
          (tester) async {
            final rig = await _pumpRig(
              tester,
              size: size,
              textScale: scale,
              decorateTheme: _withRoboto,
            );
            rig.cloud.closeResult = _skippedResult;
            rig.cloud.closeGate = Completer<void>();
            rig.push.emitNotice(
              rig.notice(title: 'Yazlık Ev', body: _longBody),
            );
            await _settle(tester);

            await tester.tap(find.byKey(_closeAll));
            await tester.pump(const Duration(milliseconds: 60));
            expect(
              tester.takeException(),
              isNull,
              reason: 'closing satırı taşmaz',
            );
            expect(
              tester.getRect(find.byKey(_banner)).bottom,
              lessThanOrEqualTo(size.height),
            );
            final closing = tester.getRect(find.byKey(_closeAll));
            expect(closing.right, lessThanOrEqualTo(size.width));

            rig.cloud.closeGate!.complete();
            await _settle(tester);
            expect(tester.takeException(), isNull);
            expect(find.byKey(_snack), findsOneWidget);
            expect(find.text(_skippedMessage), findsOneWidget);
            expect(
              tester.getRect(find.byKey(_snack)).bottom,
              lessThanOrEqualTo(size.height),
            );
          },
          skip: fontsDir == null,
        );

        testWidgets('yumuşak istem, $tag: taşma yok, düğmeler erişilebilir', (
          tester,
        ) async {
          await _pumpRig(
            tester,
            size: size,
            textScale: scale,
            startState: PushState.needsPermission,
            decorateTheme: _withRoboto,
          );
          await _settle(tester);
          expect(tester.takeException(), isNull);
          final banner = tester.getRect(find.byKey(_softBanner));
          expect(banner.bottom, lessThanOrEqualTo(size.height));
          for (final key in <Key>[_softAccept, _softLater]) {
            final r = tester.getRect(find.byKey(key));
            expect(r.right, lessThanOrEqualTo(size.width), reason: '$key');
            expect(r.bottom, lessThanOrEqualTo(size.height), reason: '$key');
          }
          await tester.tap(find.byKey(_softLater));
          await _settle(tester);
          expect(find.byType(MaterialBanner), findsNothing);
        }, skip: fontsDir == null);
      }
    }

    testWidgets(
      'sayfa gövdesi büyük yazıda da erişilebilir kalır (320x568, ölçek 3.0: gövde düğmesi görünür alanda)',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          size: const Size(320, 568),
          textScale: 3.0,
          decorateTheme: _withRoboto,
        );
        rig.push.emitNotice(rig.notice(title: 'Yazlık Ev', body: _longBody));
        await _settle(tester);
        final banner = tester.getRect(find.byKey(_banner));
        expect(
          568 - banner.bottom,
          greaterThan(120),
          reason: 'banner sayfaya en az ~120 dp bırakır',
        );
      },
      skip: fontsDir == null,
    );
  });

  group('sonuç iletisi (SnackBar): büyük yazı, süre ve ömür döngüsü (RR2-01/02/03)', () {
    setUpAll(() async {
      if (fontsDir != null) await _loadRoboto(fontsDir);
    });

    /// Sonuç SnackBar'ı gösterilmiş durumda (afiş açık: kısmi sonuç) bir kurulum döndürür.
    Future<PeaceUiRig> pumpWithResult(
      WidgetTester tester, {
      Size size = const Size(360, 740),
      double scale = 1.0,
      bool roboto = true,
      bool realSkipped = false,
    }) async {
      final rig = await _pumpRig(
        tester,
        size: size,
        textScale: scale,
        decorateTheme: roboto ? _withRoboto : null,
      );
      if (realSkipped) {
        rig.cloud.closeResult = _realSkippedResult;
      } else {
        // Uzun sunucu iletisi (hata yolu): afiş açık kalır, ileti SnackBar'a olduğu gibi düşer.
        rig.cloud.closeError = const ApiException(
          statusCode: 409,
          code: 'PARTIAL',
          message: _realServerMessage,
        );
      }
      rig.push.emitNotice(rig.notice(title: 'Yazlık Ev'));
      await _settle(tester);
      await tester.tap(find.byKey(_closeAll));
      await _settle(tester);
      expect(find.byKey(_snack), findsOneWidget);
      return rig;
    }

    for (final size in <Size>[const Size(360, 740), const Size(320, 568)]) {
      for (final scale in <double>[1.0, 1.5, 2.0, 3.0]) {
        final tag = '${size.width.toInt()}x${size.height.toInt()} ölçek $scale';
        testWidgets(
          'gerçek uzunlukta ileti, $tag: SnackBar ekranın yarısını aşmaz; kapatma simgesi ekranda ve dokunulabilir',
          (tester) async {
            await pumpWithResult(tester, size: size, scale: scale);
            expect(tester.takeException(), isNull);

            final snack = tester.getRect(find.byKey(_snack));
            expect(
              snack.height,
              lessThanOrEqualTo(size.height * 0.5),
              reason: 'toplam yükseklik <= %50 (ölçülen ${snack.height})',
            );
            expect(snack.bottom, lessThanOrEqualTo(size.height));
            expect(snack.left, greaterThanOrEqualTo(0));
            expect(snack.right, lessThanOrEqualTo(size.width));

            final close = tester.getRect(_snackClose);
            expect(close.left, greaterThanOrEqualTo(0));
            expect(close.right, lessThanOrEqualTo(size.width));
            expect(close.top, greaterThanOrEqualTo(0));
            expect(close.bottom, lessThanOrEqualTo(size.height));
            expect(close.height, greaterThanOrEqualTo(40));

            // Gerçekten dokunulabilir (üstü başka öğeyle örtülü değil): dokunuş SnackBar'ı kapatır.
            await tester.tap(_snackClose);
            await _settle(tester);
            expect(
              find.byKey(_snack),
              findsNothing,
              reason: 'kapatma simgesine dokunuş iletiyi kapatır',
            );
            expect(
              find.byKey(_banner),
              findsOneWidget,
              reason: 'afiş açık kalır',
            );
          },
          skip: fontsDir == null,
        );
      }
    }

    testWidgets(
      'ileti metni yazı ölçeğini 1.5 ile sınırlar ve en çok 6 satır gösterir (sonuna "…"); tam metin ekran okuyucuda',
      (tester) async {
        final handle = tester.ensureSemantics();
        await pumpWithResult(tester, size: const Size(320, 568), scale: 3.0);
        final text = find.descendant(
          of: find.byKey(_snack),
          matching: find.text(_realServerMessage),
        );
        expect(text, findsOneWidget);
        final widget = tester.widget<Text>(text);
        expect(widget.maxLines, 6);
        expect(widget.overflow, TextOverflow.ellipsis);
        final scaler = MediaQuery.textScalerOf(tester.element(text));
        expect(
          scaler.scale(10),
          lessThanOrEqualTo(15.0 + 1e-6),
          reason: 'ölçek 3.0 iken içerik 1.5 ile sınırlı',
        );
        expect(
          tester.getSemantics(text).label,
          _realServerMessage,
          reason: 'görsel kısaltma ekran okuyucuyu kısaltmaz',
        );
        handle.dispose();
      },
      skip: fontsDir == null,
    );

    for (final size in <Size>[const Size(360, 740), const Size(320, 568)]) {
      for (final scale in <double>[1.0, 1.5, 2.0, 3.0]) {
        final tag = '${size.width.toInt()}x${size.height.toInt()} ölçek $scale';
        testWidgets(
          'kısmi sonuç + gerçek sunucu iletisi, $tag: KISA ileti gösterilir, talimat başta, hiç kısalmaz',
          (tester) async {
            await pumpWithResult(
              tester,
              size: size,
              scale: scale,
              realSkipped: true,
            );
            expect(tester.takeException(), isNull);
            final text = find.descendant(
              of: find.byKey(_snack),
              matching: find.text(_skippedMessage),
            );
            expect(text, findsOneWidget);
            expect(
              find.text(_realServerMessage),
              findsNothing,
              reason: 'uzun sunucu iletisi gösterilmez',
            );
            final paragraph = tester.renderObject<RenderParagraph>(
              find.descendant(of: text, matching: find.byType(RichText)),
            );
            expect(
              paragraph.didExceedMaxLines,
              isFalse,
              reason:
                  'ileti 6 satıra sığar: sonu (talimat) görsel olarak kısalmaz',
            );
            expect(
              tester.getRect(find.byKey(_snack)).height,
              lessThanOrEqualTo(size.height * 0.4),
              reason: 'SnackBar yüksekliği ekranın %40 ını aşmaz',
            );
          },
          skip: fontsDir == null,
        );
      }
    }

    testWidgets(
      'kalıcı değil: 8 sn sonra kalkar ve sayfanın kendi SnackBar\'ı kuyrukta beklemeden görünür olur',
      (tester) async {
        await pumpWithResult(tester, roboto: false);
        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .showSnackBar(const SnackBar(content: Text('Kural kaydedildi')));
        await tester.pump();
        expect(
          find.text('Kural kaydedildi'),
          findsNothing,
          reason: 'sonuç iletisi ekranda iken sayfa iletisi sırada',
        );

        await tester.pump(const Duration(seconds: 7));
        expect(find.byKey(_snack), findsOneWidget, reason: '8 sn dolmadı');
        await tester.pump(const Duration(seconds: 2));
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byKey(_snack), findsNothing);
        expect(
          find.text('Kural kaydedildi'),
          findsOneWidget,
          reason: 'sayfa iletisi süresiz beklemez',
        );
        // Dokunulmazsa dakikalarca kalmaz.
        await tester.pump(const Duration(seconds: 60));
        await tester.pumpAndSettle();
        expect(find.byKey(_snack), findsNothing);
      },
    );

    testWidgets(
      'oturum bitince (çıkış) SnackBar hemen kalkar; giriş ekranında bayat ileti kalmaz',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        rig.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
        await _settle(tester);
        expect(find.byKey(_snack), findsNothing);
        expect(find.byType(MaterialBanner), findsNothing);
      },
    );

    testWidgets(
      'denetleyici uygun olmayınca (rol kaybı: yalnızca misafir ev kaldı) SnackBar kalkar; oturum açık',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        final guest = testHome(id: kHomeB, name: 'Misafir ev', role: 'guest');
        rig.state.setHomesForTesting(<HomeModel>[guest], activeHome: guest);
        await _settle(tester);
        expect(rig.controller.isEligible, isFalse);
        expect(rig.state.isAuthenticated, isTrue);
        expect(find.byKey(_snack), findsNothing);
      },
    );

    testWidgets(
      'yeni bir bildirim afişi gelince (afiş açıkken) eski sonucun SnackBar\'ı kalkar; yeni afiş görünür',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        rig.push.emitNotice(rig.notice(id: 42, body: 'Yeni bildirim.'));
        await _settle(tester);
        expect(find.text('Yeni bildirim.'), findsOneWidget);
        expect(find.byKey(_snack), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'iş bitip afiş kalkınca gelen yeni bildirim de eski sonucun SnackBar\'ını kaldırır',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        await tester.tap(find.byKey(_closeAll));
        await _settle(tester);
        expect(find.byKey(_banner), findsNothing);
        expect(find.byKey(_snack), findsOneWidget);

        rig.push.emitNotice(rig.notice(id: 43, body: 'Başka bildirim.'));
        await _settle(tester);
        expect(find.text('Başka bildirim.'), findsOneWidget);
        expect(find.byKey(_snack), findsNothing);
      },
    );

    testWidgets(
      'aynı bildirimin güncel özeti (aynı dedupeKey) sonuç SnackBar\'ını kaldırmaz',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        rig.push.emitNotice(rig.notice(body: 'Salonda 1 lamba açık.'));
        await _settle(tester);
        expect(find.byKey(_snack), findsOneWidget);
      },
    );

    testWidgets(
      'aynı bildirimin yeniden gösterimi (tema değişimi) sonuç SnackBar\'ını kaldırmaz',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        await tester.pumpWidget(peaceApp(rig: rig, themeMode: ThemeMode.dark));
        // Banner yeni temaya göre yeniden gösterilir (kaldırma + giriş animasyonları; SnackBar'ın 8 sn'lik
        // zamanlayıcısı kare üretmez, pumpAndSettle onu ilerletmez).
        await _settle(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(_banner), findsOneWidget);
        final bannerMaterial = tester.widget<Material>(
          find
              .descendant(
                of: find.byKey(_banner),
                matching: find.byType(Material),
              )
              .first,
        );
        expect(
          bannerMaterial.color,
          AppTheme.cardDark,
          reason: 'afiş gerçekten yeniden gösterildi (yeni tema)',
        );
        expect(
          find.byKey(_snack),
          findsOneWidget,
          reason: 'aynı bildirim: iletisi bayat değil',
        );
      },
    );

    testWidgets(
      'kuyrukta beklerken kaldırılması istenen SnackBar (başka SnackBar çıkış animasyonunda) görünür görünmez kapanır; çökme yok',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.cloud.closeResult = _skippedResult;
        await _showNotice(tester, rig);
        final messenger = ScaffoldMessenger.of(
          tester.element(find.byKey(_pageButton)),
        );
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Sayfa iletisi'),
            duration: Duration(seconds: 30),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Sayfa iletisi'), findsOneWidget);

        // Sonuç gelir: sayfa iletisi çıkış animasyonuna girer, sonuç iletisi KUYRUĞA girer...
        await tester.tap(find.byKey(_closeAll));
        await tester.pump();
        await tester.pump();
        // ...ve henüz görünmeden oturum biter: kuyruktaki ileti de gösterilmemeli.
        rig.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(seconds: 2));
        expect(
          find.byKey(_snack),
          findsNothing,
          reason: 'bayat sonuç iletisi sıradan çıkınca da gösterilmez',
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('köprü ağaçtan kalkınca gösterdiği SnackBar da kalkar', (
      tester,
    ) async {
      final rig = await _pumpRig(tester);
      final showHost = ValueNotifier<bool>(true);
      addTearDown(showHost.dispose);
      await tester.pumpWidget(
        ChangeNotifierProvider<AutomationState>.value(
          value: rig.state,
          child: MaterialApp(
            builder: (context, child) =>
                ChangeNotifierProvider<PeaceNoticeController>.value(
                  value: rig.controller,
                  child: ValueListenableBuilder<bool>(
                    valueListenable: showHost,
                    builder: (_, show, _) =>
                        show ? PeaceNoticeHost(child: child!) : child!,
                  ),
                ),
            home: const DemoPage(),
          ),
        ),
      );
      rig.cloud.closeResult = _skippedResult;
      await _showNotice(tester, rig);
      await tester.tap(find.byKey(_closeAll));
      await _settle(tester);
      expect(find.byKey(_snack), findsOneWidget);

      showHost.value = false;
      await _settle(tester);
      expect(find.byKey(_snack), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'kendiliğinden kapanmış SnackBar\'dan sonra oturum bitse de başka bir (sayfa) SnackBar\'ı kapanmaz',
      (tester) async {
        final rig = await pumpWithResult(tester, roboto: false);
        await tester.tap(_snackClose);
        await _settle(tester);
        expect(find.byKey(_snack), findsNothing);

        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .showSnackBar(
              const SnackBar(
                content: Text('Sayfa iletisi'),
                duration: Duration(seconds: 30),
              ),
            );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Sayfa iletisi'), findsOneWidget);

        rig.state.setAuthStatusForTesting(AuthStatus.unauthenticated);
        await _settle(tester);
        expect(
          find.text('Sayfa iletisi'),
          findsOneWidget,
          reason: 'köprü yalnızca kendi gösterdiği SnackBar\'ı kaldırır',
        );
      },
    );
  });

  group('metin bölgesi kaydırma ve harici banner kaldırma (RR2-04)', () {
    setUpAll(() async {
      if (fontsDir != null) await _loadRoboto(fontsDir);
    });

    testWidgets(
      'uzun gövde kaydırılabilir: sürükleyince Scrollable konumu değişir ve gövdenin son satırı görünür olur',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          size: const Size(320, 568),
          textScale: 2.0,
          decorateTheme: _withRoboto,
        );
        rig.push.emitNotice(rig.notice(title: 'Yazlık Ev', body: _longBody));
        await _settle(tester);

        final scroll = find.descendant(
          of: find.byKey(_banner),
          matching: find.byType(SingleChildScrollView),
        );
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: scroll, matching: find.byType(Scrollable)),
        );
        final viewport = tester.getRect(scroll);
        expect(
          scrollable.position.maxScrollExtent,
          greaterThan(0),
          reason: 'içerik sınırlı alana sığmıyor: kaydırma gerekli',
        );
        expect(scrollable.position.pixels, 0);
        expect(
          tester.getRect(find.byKey(_body)).bottom,
          greaterThan(viewport.bottom + 0.5),
          reason: 'başta gövdenin sonu görünür alanın dışında',
        );

        await tester.drag(scroll, const Offset(0, -2000));
        await tester.pump();
        expect(
          scrollable.position.pixels,
          greaterThan(0),
          reason: 'drag sonrası kaydırma konumu değişti',
        );
        expect(
          scrollable.position.pixels,
          closeTo(scrollable.position.maxScrollExtent, 0.5),
        );
        expect(
          tester.getRect(find.byKey(_body)).bottom,
          lessThanOrEqualTo(viewport.bottom + 0.5),
          reason: 'sona kaydırınca gövdenin son satırı görünür',
        );
        expect(tester.takeException(), isNull);
      },
      skip: fontsDir == null,
    );

    testWidgets(
      'dışarıdan removeCurrentMaterialBanner (kullanıcı kararı değil): afiş yeniden gösterilir, bildirim korunur',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .removeCurrentMaterialBanner();
        await _settle(tester);
        expect(rig.controller.pending, isNotNull);
        expect(find.byType(MaterialBanner), findsOneWidget);
        expect(find.byKey(_banner), findsOneWidget);
      },
    );

    testWidgets(
      'dışarıdan hideCurrentMaterialBanner: afiş yeniden gösterilir, bildirim korunur',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .hideCurrentMaterialBanner();
        await _settle(tester);
        expect(rig.controller.pending, isNotNull);
        expect(find.byType(MaterialBanner), findsOneWidget);
      },
    );

    testWidgets(
      'dışarıdan clearMaterialBanners: yumuşak istem de yeniden gösterilir, "kullanıcı kapattı" sayılmaz',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          startState: PushState.needsPermission,
        );
        await _settle(tester);
        expect(find.byKey(_softBanner), findsOneWidget);
        ScaffoldMessenger.of(tester.element(find.byKey(_pageButton)))
            .clearMaterialBanners();
        await _settle(tester);
        expect(find.byKey(_softBanner), findsOneWidget);
        expect(rig.store.prompted, isFalse, reason: 'bir daha sorulmaz DEĞİL');
      },
    );

    testWidgets(
      'bildirim değişimi sonrası "Kapat": kalıntı/yinelenen banner yok',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        await _showNotice(tester, rig, id: 42);
        expect(find.byType(MaterialBanner), findsOneWidget);
        await tester.tap(find.byKey(_dismiss));
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(MaterialBanner), findsNothing);
      },
    );
  });

  group('kilit ekrani (biyometrik yeniden kilit)', () {
    testWidgets(
      'kilitliyken bekleyen afiş gizlenir; kilit açılınca aynı afiş geri gelir',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        expect(find.byKey(_banner), findsOneWidget);

        rig.state.setAuthStatusForTesting(AuthStatus.checking);
        await _settle(tester);
        expect(rig.controller.isLocked, isTrue);
        expect(
          rig.controller.pending,
          isNotNull,
          reason: 'kilit oturum bitişi değil: afiş korunur',
        );
        expect(find.byType(MaterialBanner), findsNothing);
        expect(find.text('Salonda 2 lamba, 1 panjur açık.'), findsNothing);

        rig.state.setAuthStatusForTesting(AuthStatus.authenticated);
        await _settle(tester);
        expect(rig.controller.isLocked, isFalse);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_body), findsOneWidget);
      },
    );

    testWidgets(
      'kilitliyken yumuşak izin istemi de gizlenir; kilit açılınca gelir',
      (tester) async {
        final rig = await _pumpRig(
          tester,
          startState: PushState.needsPermission,
        );
        await _settle(tester);
        expect(find.byKey(_softBanner), findsOneWidget);

        rig.state.setAuthStatusForTesting(AuthStatus.checking);
        await _settle(tester);
        expect(find.byType(MaterialBanner), findsNothing);

        rig.state.setAuthStatusForTesting(AuthStatus.authenticated);
        await _settle(tester);
        expect(find.byKey(_softBanner), findsOneWidget);
      },
    );
  });

  // Zorunlu parola değişimi: oturum açık + mustChangePassword iken AuthGate pano/oturum verisi göstermez
  // (forcedPasswordChange). Afiş, istem ve "Hepsini kapat" bu ekranda da görünmemeli; parola değişince
  // bekleyen afiş geri gelir.
  group('zorunlu parola değişimi ekranı (oturum açık + mustChangePassword)', () {
    UserModel user({required bool mustChange}) => UserModel(
      id: 'user-1',
      email: 'a@b.c',
      fullName: 'Ayşe',
      role: 'user',
      mustChangePassword: mustChange,
    );

    testWidgets(
      'bekleyen afiş ve "Hepsini kapat" gizlenir; parola değişince aynı afiş geri gelir',
      (tester) async {
        final rig = await _pumpRig(tester);
        await _showNotice(tester, rig);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_closeAll), findsOneWidget);

        rig.state.setCurrentUserForTesting(user(mustChange: true));
        await _settle(tester);
        expect(rig.state.mustChangePassword, isTrue);
        expect(rig.controller.isLocked, isTrue);
        expect(
          rig.controller.pending,
          isNotNull,
          reason: 'zorunlu parola değişimi oturum bitişi değil: afiş korunur',
        );
        expect(find.byType(MaterialBanner), findsNothing);
        expect(find.byKey(_closeAll), findsNothing);
        expect(find.text('Salonda 2 lamba, 1 panjur açık.'), findsNothing);

        rig.state.setCurrentUserForTesting(user(mustChange: false));
        await _settle(tester);
        expect(rig.controller.isLocked, isFalse);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_closeAll), findsOneWidget);
        expect(find.byKey(_body), findsOneWidget);
      },
    );

    testWidgets(
      'zorunlu parola ekranı sürerken gelen afiş de gösterilmez; parola değişince görünür',
      (tester) async {
        final rig = await _pumpRig(tester);
        rig.state.setCurrentUserForTesting(user(mustChange: true));
        await _settle(tester);

        await _showNotice(tester, rig);
        expect(rig.controller.pending, isNotNull);
        expect(find.byType(MaterialBanner), findsNothing);
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(MaterialBanner), findsNothing);

        rig.state.setCurrentUserForTesting(user(mustChange: false));
        await _settle(tester);
        expect(find.byKey(_banner), findsOneWidget);
        expect(find.byKey(_body), findsOneWidget);
      },
    );

    testWidgets('yumuşak izin istemi de gizlenir; parola değişince gelir', (
      tester,
    ) async {
      final rig = await _pumpRig(tester, startState: PushState.needsPermission);
      await _settle(tester);
      expect(find.byKey(_softBanner), findsOneWidget);

      rig.state.setCurrentUserForTesting(user(mustChange: true));
      await _settle(tester);
      expect(find.byType(MaterialBanner), findsNothing);

      rig.state.setCurrentUserForTesting(user(mustChange: false));
      await _settle(tester);
      expect(find.byKey(_softBanner), findsOneWidget);
    });
  });
}
