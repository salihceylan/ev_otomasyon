@Tags(['visual'])
library;

// WP-V1 CARDS görsel galerisi: panjur / lamba / DI hapı / "Hepsini Kapat" tüm durumları.
//
//   flutter test --tags visual --update-goldens test/visual/cards     -> test/visual/cards/goldens/*.png
//   AHBU_VISUAL=1 flutter test --tags visual test/visual/cards         -> kayıtlı PNG ile karşılaştırır
//
// 360 dp telefon genişliği, koyu + açık tema, yazı ölçeği 1.0 (2x PNG) ve 1.5 (1x PNG).
//
// Yüzey yüksekliği İÇERİĞE göre ölçülür (`pumpGallery(fitHeight: true)`): sabit yükseklik varsayımı alt kartı
// kırpıyordu (eleştirmen bulgusu: harness-artifact).
// Varsayılan koşuda ATLANIR (`visualSkipReason`): kayıtlı PNG'lerle piksel karşılaştırması yalnız `AHBU_VISUAL=1` ile.

import 'package:ev_otomasyon/models/automation_models.dart';
import 'package:ev_otomasyon/services/automation_state.dart';
import 'package:ev_otomasyon/ui/dashboard/close_all_lights_button.dart';
import 'package:ev_otomasyon/ui/widgets/di_status_pill.dart';
import 'package:ev_otomasyon/ui/widgets/relay_switch_card.dart';
import 'package:ev_otomasyon/ui/widgets/shutter_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/support.dart';
import '../../ui/e1_helpers.dart';
import '../support/golden_support.dart';

ShutterVm _sv({
  int pos = 40,
  bool moving = false,
  int direction = 0,
  int? target,
  String name = 'Salon Panjur',
  bool isExt = false,
  bool pending = false,
  bool offline = false,
  bool locked = false,
  bool canControl = true,
}) =>
    (
      pos: pos,
      moving: moving,
      direction: direction,
      target: target,
      name: name,
      isExt: isExt,
      pending: pending,
      offline: offline,
      canControl: canControl,
      locked: locked,
    );

RelayVm _rv({
  bool isOn = false,
  String name = 'Salon Avize',
  bool pending = false,
  bool offline = false,
  bool locked = false,
  bool canControl = true,
}) =>
    (isOn: isOn, name: name, pending: pending, offline: offline, canControl: canControl, locked: locked);

/// Kartları alt alta dizer; kendi yüksekliğini ölçer (`Column(mainAxisSize: min)`: `pumpGallery(fitHeight: true)`).
Widget _col(List<Widget> children) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [for (final c in children) Padding(padding: const EdgeInsets.only(bottom: 12), child: c)],
      ),
    );

Widget _shutter(ShutterVm vm, {int pair = 1, String? pending}) =>
    ShutterCardView(pair: pair, vm: vm, pendingAction: pending);

Widget _relay(RelayItem r, RelayVm vm) => RelayCardView(relay: r, vm: vm);

const _lamp = RelayItem(id: 1, name: 'Salon Avize', type: 0, state: false);
const _lamp2 = RelayItem(id: 2, name: 'Mutfak Tezgah Işığı', type: 0, state: false);
const _impulse = RelayItem(id: 5, name: 'Bahçe Kapısı Açıcı', type: 3, state: false);
const _ext = RelayItem(id: 11, name: 'Teras Aydınlatma', type: 0, state: false);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WP-V1 kartlar galerisi', skip: visualSkipReason, () {
    setUpAll(loadGoldenFonts);

    for (final brightness in [Brightness.dark, Brightness.light]) {
      for (final scale in [1.0, 1.5]) {
        final tag = '${brightness.name}_$scale';
        final ratio = scale > 1 ? 1.0 : 2.0;

        /// [child] içeriği 360 dp genişlikte kurar; yüzey yüksekliği içeriğe eşitlenir (üst sınır 4200 dp).
        Future<void> shoot(WidgetTester tester, String name, Widget child) async {
          final key = GlobalKey();
          await pumpGallery(
            tester,
            boundaryKey: key,
            brightness: brightness,
            textScale: scale,
            size: const Size(360, 4200),
            fitHeight: true,
            child: child,
          );
          await tester.pump(const Duration(milliseconds: 400));
          await expectGolden(tester, key, '${name}_$tag.png', pixelRatio: ratio);
          expect(tester.takeException(), isNull);
        }

        testWidgets('panjur: durgun durumlar ($tag)', (tester) async {
          await shoot(
            tester,
            'shutter_idle',
            _col([
              _shutter(_sv(pos: 40), pair: 1),
              _shutter(_sv(pos: 100, name: 'Yatak Odası Panjur'), pair: 2),
              _shutter(_sv(pos: 0, name: 'Çocuk Odası Panjur'), pair: 3),
              _shutter(_sv(pos: 40, name: 'Teras Panjur', isExt: true, locked: true), pair: 5),
            ]),
          );
        });

        testWidgets('panjur: hareketli durumlar %0/%40/%100 ($tag)', (tester) async {
          await shoot(
            tester,
            'shutter_moving',
            _col([
              _shutter(_sv(pos: 0, moving: true, direction: 1, target: 100), pair: 1),
              _shutter(_sv(pos: 40, moving: true, direction: 2, target: 0, name: 'Yatak Odası Panjur'), pair: 2),
              _shutter(_sv(pos: 100, moving: true, direction: 2, target: 0, name: 'Çocuk Odası Panjur'), pair: 3),
              _shutter(_sv(pos: 40, moving: true, direction: 1, target: 100, name: 'Mutfak Panjur'), pair: 4),
            ]),
          );
        });

        testWidgets('panjur: bekleyen / çevrimdışı ($tag)', (tester) async {
          await shoot(
            tester,
            'shutter_pending_offline',
            _col([
              _shutter(_sv(pos: 40, pending: true), pair: 1, pending: 'up'),
              _shutter(_sv(pos: 60, offline: true, name: 'Yatak Odası Panjur'), pair: 2),
            ]),
          );
        });

        testWidgets('lamba/röle kartları ($tag)', (tester) async {
          await shoot(
            tester,
            'lamps',
            _col([
              _relay(_lamp, _rv()),
              _relay(_lamp, _rv(isOn: true)),
              _relay(_lamp2, _rv(isOn: true, pending: true, name: 'Mutfak Tezgah Işığı')),
              _relay(_lamp2, _rv(isOn: true, offline: true, name: 'Mutfak Tezgah Işığı')),
              _relay(_lamp, _rv(locked: true, name: 'Koridor')),
              _relay(_ext, _rv(isOn: true, name: 'Teras Aydınlatma')),
              _relay(_ext, _rv(isOn: true, locked: true, name: 'Teras Aydınlatma Uzun Adlı Şerit LED')),
              _relay(_impulse, _rv(name: 'Bahçe Kapısı Açıcı')),
              _relay(_impulse, _rv(name: 'Bahçe Kapısı Açıcı', pending: true)),
            ]),
          );
        });

        // Salt-okunur (canControl: false): orblar ve kaydırıcı pasif; AÇIK kart kenar/bloom gösterirken orb gri kalır.
        testWidgets('salt-okunur kartlar: yetkisiz kullanıcı ($tag)', (tester) async {
          await shoot(
            tester,
            'readonly',
            _col([
              _shutter(_sv(pos: 40, canControl: false), pair: 1),
              _shutter(_sv(pos: 100, moving: true, direction: 2, target: 0, canControl: false, name: 'Yatak Odası Panjur'), pair: 2),
              _relay(_lamp, _rv(canControl: false)),
              _relay(_lamp, _rv(isOn: true, canControl: false)),
              _relay(_impulse, _rv(canControl: false, name: 'Bahçe Kapısı Açıcı')),
            ]),
          );
        });

        // Geniş (tablet / masaüstü) kart: [CardGrid] kartı mevcut genişliğe yayar; panjur kartı >= 600 dp iç genişlikte iki
        // panele geçer (solda ad + pencere + yüzde, sağda orb eylemleri + kaydırıcı). Tek kart tam genişlikte, lamba kartı bar.
        for (final width in [768.0, 1200.0]) {
          if (scale > 1 && width > 800) continue;
          testWidgets('geniş kartlar: ${width.toInt()} dp ($tag)', (tester) async {
            final key = GlobalKey();
            await pumpGallery(
              tester,
              boundaryKey: key,
              brightness: brightness,
              textScale: scale,
              size: Size(width, 4200),
              fitHeight: true,
              child: _col([
                _shutter(_sv(pos: 40), pair: 1),
                _shutter(_sv(pos: 60, moving: true, direction: 2, target: 0, name: 'Yatak Odası Panjur', isExt: true, locked: true), pair: 2),
                _shutter(_sv(pos: 60, offline: true, name: 'Çocuk Odası Panjur'), pair: 3),
                _relay(_lamp, _rv(isOn: true)),
                _relay(_ext, _rv(isOn: true, locked: true, name: 'Teras Aydınlatma Uzun Adlı Şerit LED')),
              ]),
            );
            await tester.pump(const Duration(milliseconds: 400));
            await expectGolden(tester, key, 'wide_${width.toInt()}_$tag.png', pixelRatio: ratio);
            expect(tester.takeException(), isNull);
          });
        }

        testWidgets('DI hapları ve Hepsini Kapat ($tag)', (tester) async {
          final h = (await tester.runAsync(() => e1Ready()))!;
          addTearDown(h.dispose);
          h.mqtt.emitStateJson(stateJson(childLock: true));
          await tester.runAsync(() => pumpEventQueue());
          await shoot(
            tester,
            'di_and_close_all',
            ChangeNotifierProvider<AutomationState>.value(
              value: h.state,
              child: _col([
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    DIStatusPill(di: DIItem(id: 1, name: 'Giriş 1', state: true)),
                    DIStatusPill(di: DIItem(id: 2, name: 'Giriş 2', state: false)),
                    // Uzun ad: ek modül (kimlik > 8) + iki haneli kimlik + kilit (hap büyümez, ad kesilir).
                    DIStatusPill(di: DIItem(id: 12, name: 'Giriş 12', state: true)),
                    DIStatusPill(di: DIItem(id: 13, name: 'Giriş 13', state: false)),
                  ],
                ),
                const Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    CloseAllLightsButton(filled: true),
                    // Varsayılan renk (AppFamilies.sky.deep) ve ayarlar kartındaki amber kullanım.
                    CloseAllLightsButton(filled: false),
                    CloseAllLightsButton(filled: false, color: Colors.amber),
                  ],
                ),
              ]),
            ),
          );
        });
      }
    }
  });
}
