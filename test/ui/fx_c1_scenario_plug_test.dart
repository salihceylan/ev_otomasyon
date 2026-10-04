import 'dart:async';

import 'package:ev_otomasyon/models/api_models.dart';
import 'package:ev_otomasyon/models/cloud_models.dart';
import 'package:ev_otomasyon/ui/dashboard/apartment_dashboard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/support.dart';
import 'e1_helpers.dart';

/// DAIRE-01 (D18, istemci doğrulaması): Hızlı Senaryolar ham `{cmd:'all_lights_off'}` gönderir; sunucu (S1) evde priz
/// (`plug`) varsa YALNIZ açık lambaları kapatır, prizleri korur (yanıt biçimi aynı).
///
/// İstemcide değişiklik GEREKMEZ, çünkü:
/// * toplu komutun iyimser hedefi yoktur (`cmdAll`: `target: null`; iyimser katman yalnız `relay:N` / `shutter:N` /
///   `childLock` anahtarlarına uygulanır): ne lamba ne priz kartı komut uçuştayken değiştirilir;
/// * kartların son hali panonun bildirdiği gerçek durumdan gelir; açık lamba sayacı ve huzur bandı yalnız `isLight`
///   (priz hariç) uç noktaları sayar.
///
/// Bu dosya davranışı KİLİTLER (üretim kodu değiştirilmedi; testler ilk koşuda yeşildir).
void main() {
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Lambalar (1, 2, 5) ve priz (6) AÇIK.
  List<EndpointModel> litWithPlug() => testEndpoints()
      .map((e) => (e.isLight || e.endpointType == 'plug') ? e.copyWith(currentState: true) : e)
      .toList();

  testWidgets('"Tüm Lambalar": tek all_lights_off gider; uçuşta priz/lamba kartı iyimser değişmez; pano bildirince priz AÇIK kalır',
      (tester) async {
    final h = await pumpReady(tester, const Scaffold(body: ApartmentDashboard()),
        endpoints: litWithPlug(), size: const Size(800, 3000));
    bool plugOn() => h.state.cloudEndpoints.firstWhere((e) => e.channel == 6).currentState;
    expect(plugOn(), isTrue);
    expect(h.state.openLightsCount, 3, reason: 'priz açık lamba sayılmaz');

    final gate = Completer<CommandResult>();
    h.e1.sendCommandHandler = (home, device, command) => gate.future;
    await tester.ensureVisible(byKeyName('card_scenario_lights_off'));
    await tester.tap(byKeyName('card_scenario_lights_off'));
    await tester.pump();

    // Komut uçuşta: iyimser hedef yok (ne priz ne lamba kartı değişir).
    expect(plugOn(), isTrue);
    expect(h.state.openLightsCount, 3);
    expect(find.descendant(of: byKeyName('card_relay_6'), matching: find.text('AÇIK')), findsOneWidget);

    gate.complete(deliveredResult());
    await flush(tester);
    expect(h.e1.sentCommands, hasLength(1));
    expect(h.e1.sentCommands.single['cmd'], 'all_lights_off', reason: 'kanal bazlı komut üretilmez; plug kuralı sunucuda');
    expect(h.e1.sentCommands.single.containsKey('relay'), isFalse);

    // Sunucunun plug kuralı: pano yalnız lambaları kapattı, priz açık kaldı.
    h.mqtt.emitStateJson(stateJson(relays: const <int, bool>{1: false, 2: false, 5: false, 6: true}));
    await flush(tester);
    expect(plugOn(), isTrue);
    expect(find.descendant(of: byKeyName('card_relay_6'), matching: find.text('AÇIK')), findsOneWidget);
    expect(h.state.openLightsCount, 0);
    expect(byKeyName('banner_peace'), findsNothing, reason: 'açık lamba kalmadı (priz lamba sayılmaz)');
  });
}
